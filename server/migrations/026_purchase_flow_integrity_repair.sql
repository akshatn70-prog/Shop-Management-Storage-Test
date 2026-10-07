-- Migration 026: purchase flow integrity repair.
-- Keeps migration 025 unchanged.
-- Ensures credit purchases validate the debtor against the current shop
-- before writing the purchase and verifies that the purchase actually updates
-- product stock.
--
-- The existing debtor-credit ledger trigger from migration 025 remains the
-- single ledger writer, so this migration does not create duplicate ledger
-- entries.

create or replace function public.add_inventory_purchase(
  p_product_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_purchase_unit text,
  p_purchase_price numeric,
  p_payment_mode text default 'cash',
  p_cash_amount numeric default 0,
  p_upi_amount numeric default 0,
  p_credit_amount numeric default 0,
  p_debtor_id uuid default null,
  p_pre_stock boolean default false,
  p_supplier_name text default null,
  p_selling_price numeric default null
) returns uuid
language plpgsql
security definer
set search_path=''
as $purchase$
declare
  p public.products;
  total numeric;
  cash numeric := coalesce(p_cash_amount,0);
  upi numeric := coalesce(p_upi_amount,0);
  credit numeric := coalesce(p_credit_amount,0);
  v_id uuid;
  v_shop_id text;
  is_pre_stock boolean := coalesce(p_pre_stock,false) or p_payment_mode='pre_stock';
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  v_shop_id := (
    select pr.shop_id
    from public.profiles pr
    where pr.id=(select auth.uid())
      and pr.is_active=true
  );

  if v_shop_id is null or btrim(v_shop_id)='' then
    raise exception 'Shop ID is not configured';
  end if;

  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_purchase_price < 0 then
    raise exception 'Invalid purchase';
  end if;

  if p_selling_price is not null and p_selling_price < 0 then
    raise exception 'Invalid selling price';
  end if;

  if p_payment_mode not in ('cash','upi','split','credit','pre_stock') then
    raise exception 'Invalid payment mode';
  end if;

  select *
  into p
  from public.products
  where id=p_product_id
    and is_active=true
  for update;

  if not found then
    raise exception 'Product not found';
  end if;

  if p.unit_type='piece' then
    if p_purchase_unit<>'piece'
       or p_quantity_base<>p_quantity_display
       or mod(p_quantity_base,1)<>0
    then
      raise exception 'Piece purchases must use whole pieces';
    end if;
  else
    if p_purchase_unit not in ('grams','kg') then
      raise exception 'Weight purchases must use grams or kg';
    end if;

    if p_purchase_unit='kg'
       and p_quantity_base<>p_quantity_display*1000
    then
      raise exception 'Invalid kg purchase quantity';
    end if;

    if p_purchase_unit='grams'
       and p_quantity_base<>p_quantity_display
    then
      raise exception 'Invalid gram purchase quantity';
    end if;
  end if;

  if p.unit_type='weight' then
    total:=round((p_quantity_base/1000)*p_purchase_price,2);
  else
    total:=round(p_quantity_base*p_purchase_price,2);
  end if;

  if is_pre_stock then
    cash:=0;
    upi:=0;
    credit:=0;
    p_payment_mode:='pre_stock';
  elsif p_payment_mode='cash' then
    cash:=total;
    upi:=0;
    credit:=0;
  elsif p_payment_mode='upi' then
    cash:=0;
    upi:=total;
    credit:=0;
  elsif p_payment_mode='credit' then
    cash:=0;
    upi:=0;
    credit:=total;
  elsif p_payment_mode='split' then
    if cash<0 or upi<0 or abs(cash+upi-total)>0.01 then
      raise exception 'Cash + UPI must equal purchase total';
    end if;
    credit:=0;
  end if;

  if not is_pre_stock
     and abs(cash+upi+credit-total)>0.01
  then
    raise exception 'Purchase payment amounts must equal purchase total';
  end if;

  if credit>0 then
    if p_debtor_id is null then
      raise exception 'Credit purchase requires a debtor';
    end if;

    if not exists(
      select 1
      from public.debtors d
      where d.id=p_debtor_id
        and d.shop_id=v_shop_id
        and d.is_active=true
    ) then
      raise exception 'Debtor not found for this shop';
    end if;
  elsif p_debtor_id is not null then
    raise exception 'Debtor is only valid for credit purchases';
  end if;

  insert into public.inventory_purchases(
    product_id,
    product_name_snapshot,
    quantity_base,
    quantity_display,
    purchase_unit,
    purchase_price_per_base_unit,
    total_cost,
    purchased_by,
    payment_mode,
    cash_amount,
    upi_amount,
    credit_amount,
    credit_paid,
    pre_stock,
    supplier_name,
    debtor_id
  )
  values(
    p_product_id,
    p.name,
    p_quantity_base,
    p_quantity_display,
    p_purchase_unit,
    p_purchase_price,
    total,
    auth.uid(),
    p_payment_mode,
    round(cash,2),
    round(upi,2),
    round(credit,2),
    0,
    is_pre_stock,
    coalesce(nullif(trim(coalesce(p_supplier_name,'')),''),p.name),
    p_debtor_id
  )
  returning id into v_id;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base=current_stock_base+p_quantity_base,
      purchase_price_per_base_unit=p_purchase_price,
      selling_price_per_base_unit=coalesce(p_selling_price,selling_price_per_base_unit),
      updated_at=now()
  where id=p_product_id
    and is_active=true;

  perform set_config('shop.allow_stock_change','off',true);

  if not exists(
    select 1
    from public.products
    where id=p_product_id
      and current_stock_base >= p_quantity_base
  ) then
    raise exception 'Purchase was recorded but product stock was not updated';
  end if;

  perform public.write_audit(
    'purchase_added',
    'inventory_purchase',
    v_id,
    jsonb_build_object(
      'total',total,
      'payment_mode',p_payment_mode,
      'selling_price',coalesce(p_selling_price,p.selling_price_per_base_unit)
    )
  );

  perform public.refresh_daily_financial_summary(
    v_shop_id,
    public.business_date(
      (select i.purchased_at
       from public.inventory_purchases i
       where i.id=v_id)
    )
  );

  perform public.refresh_lifetime_financial_summary(v_shop_id);

  return v_id;
end;
$purchase$;

revoke all on function public.add_inventory_purchase(
  uuid,
  numeric,
  numeric,
  text,
  numeric,
  text,
  numeric,
  numeric,
  numeric,
  uuid,
  boolean,
  text,
  numeric
) from public, anon;

grant execute on function public.add_inventory_purchase(
  uuid,
  numeric,
  numeric,
  text,
  numeric,
  text,
  numeric,
  numeric,
  numeric,
  uuid,
  boolean,
  text,
  numeric
) to authenticated;

insert into public.shop_management_schema_version(version)
values (26)
on conflict (version) do nothing;

select pg_notify('pgrst','reload schema');