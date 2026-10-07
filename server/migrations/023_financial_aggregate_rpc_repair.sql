-- Financial aggregate RPC repair v3.
-- Transaction RPCs refresh daily/lifetime summaries before returning success.
-- Existing triggers remain as a safety net for direct DB mutations.

create or replace function public.complete_cart_sale(
  p_worker_id uuid,
  p_items jsonb,
  p_payment_mode text,
  p_cash_amount numeric default 0,
  p_upi_amount numeric default 0,
  p_credit_amount numeric default 0,
  p_creditor_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_tx_id uuid;
  v_invoice text;
  v_creditor public.creditors;
  item jsonb;
  product_id uuid;
  product_row public.products;
  qty_base numeric;
  qty_display numeric;
  sold_unit text;
  selling_price numeric;
  line_total numeric;
  line_cost numeric;
  line_profit numeric;
  total numeric := 0;
  total_cost numeric := 0;
  cash_paid numeric := coalesce(p_cash_amount,0);
  upi_paid numeric := coalesce(p_upi_amount,0);
  credit_paid numeric := coalesce(p_credit_amount,0);
  actual_payment_mode text;
  is_owner_user boolean;
  can_change_price boolean;
  locked_ids uuid[];
  v_existing_count integer;
  line_cash numeric;
  line_upi numeric;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;

  is_owner_user := (select public.is_owner());
  if p_worker_id <> (select auth.uid()) and not is_owner_user then
    raise exception 'Worker can only record sales for self';
  end if;

  if not exists (
    select 1 from public.profiles
    where id=p_worker_id and is_active=true
  ) then
    raise exception 'Worker account is inactive';
  end if;

  v_shop_id := (select shop_id from public.profiles where id=p_worker_id);
  if v_shop_id is null or btrim(v_shop_id)='' then
    raise exception 'Shop ID is not configured';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Cart is empty';
  end if;

  if p_payment_mode not in ('cash','upi','split','credit','credit_split') then
    raise exception 'Invalid payment mode';
  end if;

  if p_payment_mode in ('credit','credit_split') then
    if p_creditor_id is null then
      raise exception 'Creditor is required for credit sales';
    end if;
    if p_payment_mode='credit' and (cash_paid <> 0 or upi_paid <> 0 or credit_paid <= 0) then
      raise exception 'Pure credit sales cannot include Cash or UPI';
    end if;
    if p_payment_mode='credit_split' and (cash_paid < 0 or upi_paid < 0 or credit_paid <= 0 or (cash_paid + upi_paid) <= 0) then
      raise exception 'Partial credit sales require a positive credit amount and a cash or UPI payment';
    end if;
    select * into v_creditor
    from public.creditors
    where id=p_creditor_id and shop_id=v_shop_id and is_active=true;
    if not found then
      raise exception 'Creditor not found';
    end if;
  elsif p_creditor_id is not null then
    raise exception 'Creditor is only valid for credit sales';
  end if;

  if credit_paid < 0 then
    raise exception 'Credit amount cannot be negative';
  end if;

  if p_payment_mode in ('cash','upi','split','credit_split') then
    if cash_paid < 0 or upi_paid < 0 then
      raise exception 'Cash and UPI cannot be negative';
    end if;
  end if;

  select array_agg(x.product_id order by x.product_id)
  into locked_ids
  from (
    select distinct (value->>'product_id')::uuid as product_id
    from jsonb_array_elements(p_items)
    where value ? 'product_id'
  ) x;

  if coalesce(array_length(locked_ids,1),0) <> jsonb_array_length(p_items) then
    raise exception 'Every cart item must contain a valid product_id';
  end if;

  select count(*)
  into v_existing_count
  from (
    select (value->>'product_id')::uuid as product_id
    from jsonb_array_elements(p_items)
    group by (value->>'product_id')::uuid
    having count(*) > 1
  ) d;
  if v_existing_count > 0 then
    raise exception 'A product may appear only once in the cart';
  end if;

  foreach product_id in array locked_ids loop
    select * into product_row
    from public.products
    where id=product_id and is_active=true
    for update;
    if not found then
      raise exception 'Product not found';
    end if;
  end loop;

  can_change_price := is_owner_user
    or coalesce((select workers_can_modify_selling_price from public.shop_settings where id=1),false);

  foreach product_id in array locked_ids loop
    select * into product_row
    from public.products
    where id=product_id and is_active=true;

    select value into item
    from jsonb_array_elements(p_items)
    where (value->>'product_id')::uuid=product_id;

    qty_base := (item->>'quantity_base')::numeric;
    qty_display := (item->>'quantity_display')::numeric;
    sold_unit := lower(coalesce(item->>'sold_unit',''));
    selling_price := (item->>'selling_price_per_base_unit')::numeric;

    if qty_base is null or qty_display is null or qty_base <= 0 or qty_display <= 0 then
      raise exception 'Invalid cart quantity';
    end if;
    if selling_price is null or selling_price < 0 then
      raise exception 'Invalid cart selling price';
    end if;

    if not can_change_price
       and abs(selling_price - product_row.selling_price_per_base_unit) > 0.000001
    then
      raise exception 'Workers are not allowed to modify the selling price';
    end if;

    if selling_price=0
       and not coalesce((select allow_zero_price_sales from public.shop_settings where id=1),true)
    then
      raise exception 'Zero-price sales are disabled in shop settings';
    end if;

    if product_row.unit_type='piece' then
      if qty_base<>qty_display or mod(qty_base,1)<>0 or sold_unit<>'piece' then
        raise exception 'Piece quantity must be a whole number and sold in pieces';
      end if;
      line_total := round(qty_base*selling_price,2);
      line_cost := round(qty_base*product_row.purchase_price_per_base_unit,2);
    else
      if sold_unit not in ('grams','kg') then
        raise exception 'Weight products must be sold in grams or kg';
      end if;
      if sold_unit='kg' and qty_base<>qty_display*1000 then
        raise exception 'Invalid kg quantity';
      end if;
      if sold_unit='grams' and qty_base<>qty_display then
        raise exception 'Invalid gram quantity';
      end if;
      line_total := round((qty_base/1000)*selling_price,2);
      line_cost := round((qty_base/1000)*product_row.purchase_price_per_base_unit,2);
    end if;

    if product_row.current_stock_base < qty_base then
      raise exception 'Insufficient stock for %', product_row.name;
    end if;

    line_profit := line_total-line_cost;
    if line_profit < 0
       and not coalesce((select allow_below_cost_sales from public.shop_settings where id=1),true)
    then
      raise exception 'Below-cost sales are disabled in shop settings';
    end if;

    total := total + line_total;
    total_cost := total_cost + line_cost;
  end loop;

  total := round(total,2);
  total_cost := round(total_cost,2);

  if p_payment_mode in ('cash','upi','split') then
    if p_payment_mode='cash' then
      cash_paid := total;
      upi_paid := 0;
    elsif p_payment_mode='upi' then
      cash_paid := 0;
      upi_paid := total;
    elsif abs((cash_paid+upi_paid)-total)>0.01 then
      raise exception 'Cash + UPI must equal the sale total';
    end if;
    credit_paid := 0;
    actual_payment_mode := case
      when cash_paid>0 and upi_paid>0 then 'split'
      when upi_paid>0 then 'upi'
      else 'cash'
    end;
  elsif p_payment_mode='credit' then
    cash_paid := 0;
    upi_paid := 0;
    credit_paid := total;
    actual_payment_mode := 'credit';
  else
    if abs((cash_paid + upi_paid + credit_paid) - total) > 0.01 then
      raise exception 'Cash + UPI + Credit must equal the sale total';
    end if;
    actual_payment_mode := 'credit_split';
  end if;

  v_invoice := 'INV-' || to_char(now(),'YYYYMMDD') || '-' ||
    upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.sale_transactions(
    shop_id,invoice_no,worker_id,creditor_id,subtotal,total,payment_mode,
    cash_amount,upi_amount,status
  )
  values(
    v_shop_id,v_invoice,p_worker_id,p_creditor_id,total,total,
    actual_payment_mode,round(cash_paid,2),round(upi_paid,2),'confirmed'
  )
  returning id into v_tx_id;

  foreach product_id in array locked_ids loop
    select * into product_row
    from public.products
    where id=product_id and is_active=true;

    select value into item
    from jsonb_array_elements(p_items)
    where (value->>'product_id')::uuid=product_id;

    qty_base := (item->>'quantity_base')::numeric;
    qty_display := (item->>'quantity_display')::numeric;
    sold_unit := lower(item->>'sold_unit');
    selling_price := (item->>'selling_price_per_base_unit')::numeric;

    if product_row.unit_type='piece' then
      line_total := round(qty_base*selling_price,2);
      line_cost := round(qty_base*product_row.purchase_price_per_base_unit,2);
    else
      line_total := round((qty_base/1000)*selling_price,2);
      line_cost := round((qty_base/1000)*product_row.purchase_price_per_base_unit,2);
    end if;
    line_profit := line_total-line_cost;

    line_cash := 0;
    line_upi := 0;
    if actual_payment_mode='cash' then
      line_cash := line_total;
    elsif actual_payment_mode='upi' then
      line_upi := line_total;
    elsif actual_payment_mode='split' then
      line_cash := round(line_total * cash_paid / nullif(total,0),2);
      line_upi := line_total - line_cash;
    elsif actual_payment_mode='credit_split' then
      line_cash := round(line_total * cash_paid / nullif(total,0),2);
      line_upi := round(line_total * upi_paid / nullif(total,0),2);
    end if;

    insert into public.sales(
      transaction_id,product_id,worker_id,quantity_base,quantity_display,sold_unit,
      payment_mode,cash_amount,upi_amount,selling_price_per_base_unit,
      purchase_price_per_base_unit,total_sale,total_cost,gross_profit
    )
    values(
      v_tx_id,product_id,p_worker_id,qty_base,qty_display,sold_unit,
      actual_payment_mode,line_cash,line_upi,
      selling_price,product_row.purchase_price_per_base_unit,
      line_total,line_cost,line_profit
    );

    perform set_config('shop.allow_stock_change','on',true);
    update public.products
    set current_stock_base=current_stock_base-qty_base, updated_at=now()
    where id=product_id;
    perform set_config('shop.allow_stock_change','off',true);
  end loop;

  -- Reconcile per-line payment rounding for split and credit-split carts.
  -- The final line absorbs any cent remainder so line totals exactly match
  -- the transaction-level cash/UPI amounts.
  if actual_payment_mode in ('split','credit_split') then
    update public.sales s
    set cash_amount=round(greatest(0,cash_paid-coalesce((
          select sum(s2.cash_amount) from public.sales s2
          where s2.transaction_id=v_tx_id and s2.id<>s.id
        ),0)),2),
        upi_amount=round(greatest(0,upi_paid-coalesce((
          select sum(s2.upi_amount) from public.sales s2
          where s2.transaction_id=v_tx_id and s2.id<>s.id
        ),0)),2)
    where s.id=(
      select s3.id from public.sales s3
      where s3.transaction_id=v_tx_id
      order by s3.id desc
      limit 1
    );
  end if;

  if actual_payment_mode in ('credit','credit_split') then
    insert into public.credit_ledger(
      shop_id,creditor_id,sale_transaction_id,sale_id,type,amount,
      payment_mode,cash_amount,upi_amount,worker_id,notes
    )
    values(
      v_shop_id,p_creditor_id,v_tx_id,null,'credit_sale',
      credit_paid,'credit',0,0,p_worker_id,'Credit sale ' || v_invoice
    );
  end if;

  perform public.write_audit(
    'sale_created','sale_transaction',v_tx_id,
    jsonb_build_object(
      'invoice_no',v_invoice,
      'items',jsonb_array_length(p_items),
      'total',total,
      'payment_mode',actual_payment_mode,
      'creditor_id',p_creditor_id
    )
  );

  -- The RPC is the transaction boundary: refresh aggregates before reporting success.
  perform public.refresh_daily_financial_summary(
    v_shop_id,
    public.business_date((select max(s.sold_at) from public.sales s where s.transaction_id=v_tx_id))
  );
  perform public.refresh_lifetime_financial_summary(v_shop_id);

  return jsonb_build_object(
    'transaction_id',v_tx_id,
    'invoice_no',v_invoice,
    'total',total,
    'payment_mode',actual_payment_mode
  );
end;
$$;



create or replace function public.record_sale(
  p_product_id uuid,
  p_worker_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_sold_unit text,
  p_selling_price_per_base_unit numeric,
  p_payment_mode text default 'cash',
  p_cash_amount numeric default null,
  p_upi_amount numeric default null
) returns public.sales
language plpgsql security definer set search_path = ''
as $$
declare
  p public.products;
  total_sale numeric;
  total_cost numeric;
  gross numeric;
  cash_paid numeric;
  upi_paid numeric;
  actual_payment_mode text;
  result_row public.sales;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_worker_id <> (select auth.uid()) and not (select public.is_owner()) then
    raise exception 'Worker can only record sales for self';
  end if;
  if not exists (select 1 from public.profiles where id=p_worker_id and is_active=true) then
    raise exception 'Worker account is inactive';
  end if;
  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_selling_price_per_base_unit < 0 then
    raise exception 'Invalid sale';
  end if;
  if p_selling_price_per_base_unit = 0
     and not coalesce((select allow_zero_price_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Zero-price sales are disabled in shop settings';
  end if;
  if p_payment_mode not in ('cash','upi','split') then
    raise exception 'Payment mode must be cash, upi or split';
  end if;

  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;

  if p.unit_type = 'piece' then
    if p_quantity_base <> p_quantity_display or mod(p_quantity_base, 1) <> 0 or p_sold_unit <> 'piece' then
      raise exception 'Piece quantity must be a whole number and sold in pieces';
    end if;
  else
    if p_sold_unit not in ('grams','kg') then raise exception 'Weight products must be sold in grams or kg'; end if;
    if p_sold_unit = 'kg' and p_quantity_base <> p_quantity_display * 1000 then raise exception 'Invalid kg quantity'; end if;
    if p_sold_unit = 'grams' and p_quantity_base <> p_quantity_display then raise exception 'Invalid gram quantity'; end if;
  end if;

  if p.current_stock_base < p_quantity_base then raise exception 'Insufficient stock'; end if;

  if p.unit_type = 'piece' then
    total_sale := p_quantity_base * p_selling_price_per_base_unit;
    total_cost := p_quantity_base * p.purchase_price_per_base_unit;
  else
    total_sale := (p_quantity_base/1000) * p_selling_price_per_base_unit;
    total_cost := (p_quantity_base/1000) * p.purchase_price_per_base_unit;
  end if;
  gross := total_sale - total_cost;
  if gross < 0
     and not coalesce((select allow_below_cost_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Below-cost sales are disabled in shop settings';
  end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then
      cash_paid := total_sale; upi_paid := 0;
    elsif p_payment_mode='upi' then
      cash_paid := 0; upi_paid := total_sale;
    else
      raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    cash_paid := coalesce(p_cash_amount,0);
    upi_paid := coalesce(p_upi_amount,0);
  end if;

  if cash_paid < 0 or upi_paid < 0 or abs((cash_paid + upi_paid) - total_sale) > 0.01 then
    raise exception 'Cash + UPI must equal the sale total';
  end if;

  actual_payment_mode := case
    when cash_paid > 0 and upi_paid > 0 then 'split'
    when upi_paid > 0 then 'upi'
    else 'cash'
  end;

  insert into public.sales(
    product_id,product_name_snapshot,worker_id,quantity_base,quantity_display,sold_unit,payment_mode,
    cash_amount,upi_amount,selling_price_per_base_unit,purchase_price_per_base_unit,
    total_sale,total_cost,gross_profit
  )
  values(
    p_product_id,p.name,p_worker_id,p_quantity_base,p_quantity_display,p_sold_unit,actual_payment_mode,
    round(cash_paid,2),round(upi_paid,2),p_selling_price_per_base_unit,p.purchase_price_per_base_unit,
    round(total_sale,2),round(total_cost,2),round(gross,2)
  )
  returning * into result_row;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base-p_quantity_base, updated_at=now()
  where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit('sale_created','sale',result_row.id,
    jsonb_build_object(
      'product_id',p_product_id,'quantity_base',p_quantity_base,'quantity_display',p_quantity_display,
      'sold_unit',p_sold_unit,'payment_mode',actual_payment_mode,
      'cash_amount',round(cash_paid,2),'upi_amount',round(upi_paid,2),
      'selling_price_per_base_unit',p_selling_price_per_base_unit,'total_sale',round(total_sale,2)
    ));
  -- Keep reporting aggregates correct before the sale RPC returns success.
  perform public.refresh_daily_financial_summary(
    (select shop_id from public.profiles where id=result_row.worker_id),
    public.business_date(result_row.sold_at)
  );
  perform public.refresh_lifetime_financial_summary(
    (select shop_id from public.profiles where id=result_row.worker_id)
  );
  return result_row;
end;
$;



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
  is_pre_stock boolean := coalesce(p_pre_stock,false) or p_payment_mode='pre_stock';
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_purchase_price < 0 then raise exception 'Invalid purchase'; end if;
  if p_selling_price is not null and p_selling_price < 0 then raise exception 'Invalid selling price'; end if;
  if p_payment_mode not in ('cash','upi','split','credit','pre_stock') then raise exception 'Invalid payment mode'; end if;

  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;

  if p.unit_type='piece' then
    if p_purchase_unit<>'piece' or p_quantity_base<>p_quantity_display or mod(p_quantity_base,1)<>0 then
      raise exception 'Piece purchases must use whole pieces';
    end if;
  else
    if p_purchase_unit not in ('grams','kg') then raise exception 'Weight purchases must use grams or kg'; end if;
    if p_purchase_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg purchase quantity'; end if;
    if p_purchase_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram purchase quantity'; end if;
  end if;

  if p.unit_type='weight' then total:=round((p_quantity_base/1000)*p_purchase_price,2);
  else total:=round(p_quantity_base*p_purchase_price,2);
  end if;

  if is_pre_stock then
    cash:=0; upi:=0; credit:=0; p_payment_mode:='pre_stock';
  elsif p_payment_mode='cash' then
    cash:=total; upi:=0; credit:=0;
  elsif p_payment_mode='upi' then
    cash:=0; upi:=total; credit:=0;
  elsif p_payment_mode='credit' then
    cash:=0; upi:=0; credit:=total;
  elsif p_payment_mode='split' then
    if cash<0 or upi<0 or abs(cash+upi-total)>0.01 then raise exception 'Cash + UPI must equal purchase total'; end if;
    credit:=0;
  end if;

  if not is_pre_stock and abs(cash+upi+credit-total)>0.01 then
    raise exception 'Purchase payment amounts must equal purchase total';
  end if;

  if credit>0 then
    if p_debtor_id is null then raise exception 'Credit purchase requires a debtor'; end if;
    if not exists(select 1 from public.debtors where id=p_debtor_id and is_active=true) then raise exception 'Debtor not found'; end if;
  elsif p_debtor_id is not null then
    raise exception 'Debtor is only valid for credit purchases';
  end if;

  insert into public.inventory_purchases(
    product_id,product_name_snapshot,quantity_base,quantity_display,purchase_unit,
    purchase_price_per_base_unit,total_cost,purchased_by,payment_mode,cash_amount,upi_amount,
    credit_amount,credit_paid,pre_stock,supplier_name,debtor_id
  ) values(
    p_product_id,p.name,p_quantity_base,p_quantity_display,p_purchase_unit,p_purchase_price,total,
    auth.uid(),p_payment_mode,round(cash,2),round(upi,2),round(credit,2),0,is_pre_stock,
    coalesce(nullif(trim(coalesce(p_supplier_name,'')),''),p.name),p_debtor_id
  ) returning id into v_id;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base+p_quantity_base,
      purchase_price_per_base_unit=p_purchase_price,
      selling_price_per_base_unit=coalesce(p_selling_price,selling_price_per_base_unit),
      updated_at=now()
  where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit('purchase_added','inventory_purchase',v_id,
    jsonb_build_object('total',total,'payment_mode',p_payment_mode,'selling_price',coalesce(p_selling_price,p.selling_price_per_base_unit)));
  -- Keep reporting aggregates correct before the purchase RPC returns success.
  perform public.refresh_daily_financial_summary(
    (select shop_id from public.profiles where id=auth.uid()),
    public.business_date((select i.purchased_at from public.inventory_purchases i where i.id=v_id))
  );
  perform public.refresh_lifetime_financial_summary(
    (select shop_id from public.profiles where id=auth.uid())
  );
  return v_id;
end;
$purchase$;

insert into public.shop_management_schema_version(version)
values (23)
on conflict (version) do nothing;

select pg_notify('pgrst','reload schema');
