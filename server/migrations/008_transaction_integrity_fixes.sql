-- Version 8: transaction integrity fixes.
--
-- This forward migration repairs four issues in the cart/purchase workflow:
--   1. complete_cart_sale() used the right weight-price formula while
--      calculating the cart total, but used the kg formula again while
--      persisting each sales line.
--   2. pay_purchase_credit() advanced credit_paid without recording the
--      matching debtor-ledger payment.
--   3. Cart credit was implicit (total - cash - UPI) and was not persisted in
--      either sale history row, which made credit-split history ambiguous.
--   4. The old line-only void_sale() could not safely reverse a multi-line
--      cart or its customer-credit entry.
--
-- The migration is additive. Existing sale/purchase rows are retained and
-- existing RPC signatures remain available. Cart voiding appends a reversing
-- ledger entry and marks history as voided; it never deletes history.

-- ============================================================
-- 1. Persist credit on cart parents and sales lines
-- ============================================================

alter table public.sale_transactions
  add column if not exists credit_amount numeric(14,2) not null default 0,
  add column if not exists void_reason text,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references public.profiles(id);

alter table public.sales
  add column if not exists credit_amount numeric(14,2) not null default 0;

-- Backfill the amount that was previously only derivable from the payment
-- mode and cash/UPI columns. The parent update also covers transactions whose
-- detail rows have already been removed by retention cleanup.
update public.sales
set credit_amount = case
  when payment_mode='credit' then round(total_sale,2)
  when payment_mode='credit_split' then round(greatest(total_sale-cash_amount-upi_amount,0),2)
  else 0
end
where credit_amount is distinct from case
  when payment_mode='credit' then round(total_sale,2)
  when payment_mode='credit_split' then round(greatest(total_sale-cash_amount-upi_amount,0),2)
  else 0
end;

update public.sale_transactions st
set credit_amount = case
  when st.payment_mode='credit' then round(st.total,2)
  when st.payment_mode='credit_split' then round(greatest(st.total-st.cash_amount-st.upi_amount,0),2)
  else 0
end
where st.credit_amount is distinct from case
  when st.payment_mode='credit' then round(st.total,2)
  when st.payment_mode='credit_split' then round(greatest(st.total-st.cash_amount-st.upi_amount,0),2)
  else 0
end;

-- Do not infer historical price units from today's mutable product settings
-- or replace parent totals from v7's potentially incorrect gram-priced lines.
-- Existing monetary totals and ledgers need explicit reconciliation if they
-- disagree; only the previously implicit credit components are backfilled.

alter table public.sales
  drop constraint if exists sales_payment_split_check;
alter table public.sales
  add constraint sales_payment_split_check
  check (
    total_sale >= 0
    and cash_amount >= 0
    and upi_amount >= 0
    and credit_amount >= 0
    and (
      (payment_mode='credit'
        and cash_amount=0
        and upi_amount=0
        and abs(credit_amount-total_sale) <= 0.01)
      or
      (payment_mode='credit_split'
        and abs((cash_amount + upi_amount + credit_amount) - total_sale) <= 0.01)
      or
      (payment_mode in ('cash','upi','split')
        and credit_amount=0
        and abs((cash_amount + upi_amount) - total_sale) <= 0.01)
    )
  );

alter table public.sale_transactions
  drop constraint if exists sale_transactions_amounts_check;
alter table public.sale_transactions
  add constraint sale_transactions_amounts_check
  check (
    subtotal >= 0
    and total >= 0
    and cash_amount >= 0
    and upi_amount >= 0
    and credit_amount >= 0
    and (
      (payment_mode='credit'
        and cash_amount=0
        and upi_amount=0
        and abs(credit_amount-total) <= 0.01)
      or
      (payment_mode='credit_split'
        and (cash_amount + upi_amount) > 0
        and credit_amount > 0
        and abs((cash_amount + upi_amount + credit_amount) - total) <= 0.01)
      or
      (payment_mode in ('cash','upi','split')
        and credit_amount=0
        and abs((cash_amount + upi_amount) - total) <= 0.01)
    )
  );

-- A cart can contain zero-priced or one-cent lines whose rounded share of
-- one component is zero. Only the parent must be genuinely credit-split;
-- each line must have nonnegative components adding up to its own revenue.
create index if not exists credit_ledger_transaction_idx
  on public.credit_ledger(sale_transaction_id);
create index if not exists returns_sale_source_idx
  on public.returns(source_id) where return_type='sale';

-- A credit reversal is a payment_received entry with no cash/UPI component.
-- Version 5 already allowed this for sale-return adjustments; keep the same
-- invariant for cart voids on databases that were installed without v5.
alter table public.credit_ledger
  drop constraint if exists credit_ledger_payment_check;
alter table public.credit_ledger
  add constraint credit_ledger_payment_check
  check (
    (type='credit_sale'
      and payment_mode in ('credit','credit_split')
      and cash_amount=0
      and upi_amount=0)
    or
    (type='payment_received'
      and payment_mode in ('cash','upi','split')
      and cash_amount >= 0
      and upi_amount >= 0
      and abs((cash_amount + upi_amount) - amount) <= 0.01)
    or
    (type='payment_received'
      and payment_mode='credit'
      and cash_amount=0
      and upi_amount=0)
    or
    (type='adjustment')
  );

-- ============================================================
-- 2. Correct cart totals and persist all payment components
-- ============================================================

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
  cash_paid numeric := round(coalesce(p_cash_amount,0),2);
  upi_paid numeric := round(coalesce(p_upi_amount,0),2);
  credit_paid numeric := round(coalesce(p_credit_amount,0),2);
  actual_payment_mode text;
  is_owner_user boolean;
  can_change_price boolean;
  locked_ids uuid[];
  validated_lines jsonb := '[]'::jsonb;
  line_index integer := 0;
  line_count integer := 0; -- count of lines with positive rounded revenue
  remaining_total numeric := 0;
  remaining_cash numeric := 0;
  remaining_upi numeric := 0;
  remaining_credit numeric := 0;
  non_cash_remaining numeric := 0;
  line_cash numeric;
  line_upi numeric;
  line_credit numeric;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;

  is_owner_user := (select public.is_owner());
  if p_worker_id is distinct from (select auth.uid()) and not is_owner_user then
    raise exception 'Worker can only record sales for self';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id=p_worker_id and is_active=true
      and shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
  ) then
    raise exception 'Worker account is inactive';
  end if;

  v_shop_id := (select shop_id from public.profiles where id=p_worker_id);
  if v_shop_id is null or btrim(v_shop_id)='' then
    raise exception 'Shop ID is not configured';
  end if;

  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Cart items must be an array';
  end if;
  if jsonb_array_length(p_items)=0 then
    raise exception 'Cart is empty';
  end if;

  if p_payment_mode is null or p_payment_mode not in ('cash','upi','split','credit','credit_split') then
    raise exception 'Invalid payment mode';
  end if;

  if cash_paid::text in ('NaN','Infinity','-Infinity')
     or upi_paid::text in ('NaN','Infinity','-Infinity')
     or credit_paid::text in ('NaN','Infinity','-Infinity')
  then
    raise exception 'Payment amounts must be finite';
  end if;

  if p_payment_mode in ('credit','credit_split') then
    if p_creditor_id is null then
      raise exception 'Creditor is required for credit sales';
    end if;
    if p_payment_mode='credit'
       and (cash_paid <> 0 or upi_paid <> 0 or credit_paid <= 0)
    then
      raise exception 'Pure credit sales cannot include Cash or UPI';
    end if;
    if p_payment_mode='credit_split'
       and (cash_paid < 0 or upi_paid < 0 or credit_paid <= 0
            or (cash_paid + upi_paid) <= 0)
    then
      raise exception 'Partial credit sales require a positive credit amount and a cash or UPI payment';
    end if;
    select * into v_creditor
    from public.creditors
    where id=p_creditor_id and shop_id=v_shop_id and is_active=true
    for update;
    if not found then
      raise exception 'Creditor not found';
    end if;
  elsif p_creditor_id is not null then
    raise exception 'Creditor is only valid for credit sales';
  end if;

  if p_payment_mode in ('cash','upi','split','credit_split')
     and (cash_paid < 0 or upi_paid < 0)
  then
    raise exception 'Cash and UPI cannot be negative';
  end if;
  if credit_paid < 0 then
    raise exception 'Credit amount cannot be negative';
  end if;

  select array_agg(x.product_id order by x.product_id)
  into locked_ids
  from (
    select distinct (value->>'product_id')::uuid as product_id
    from jsonb_array_elements(p_items)
    where jsonb_typeof(value)='object' and value->>'product_id' is not null
  ) x;

  if coalesce(array_length(locked_ids,1),0) <> jsonb_array_length(p_items) then
    raise exception 'Every cart item must contain a distinct valid product_id';
  end if;

  -- Lock every product in deterministic order before checking stock. This
  -- makes concurrent carts serialize per product and prevents overselling.
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

  -- Compute once and retain the validated line values for persistence below.
  -- Prices are per product weight unit;
  -- quantity_base is always grams. Therefore grams pricing multiplies by the
  -- base quantity, while kg pricing divides the base quantity by 1000.
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

    if qty_base is null or qty_display is null or qty_base <= 0 or qty_display <= 0
       or qty_base::text in ('NaN','Infinity','-Infinity')
       or qty_display::text in ('NaN','Infinity','-Infinity')
       or qty_base<>round(qty_base,3) or qty_display<>round(qty_display,3)
    then
      raise exception 'Invalid cart quantity';
    end if;
    if selling_price is null or selling_price < 0
       or selling_price::text in ('NaN','Infinity','-Infinity')
    then
      raise exception 'Invalid cart selling price';
    end if;
    selling_price := round(selling_price,4);

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

      -- weight_price_unit describes the price, not the display quantity.
      -- Cache these exact rounded results instead of recalculating later.
      line_total := case
        when coalesce(product_row.weight_price_unit,'kg')='grams'
          then round(qty_base*selling_price,2)
        else round((qty_base/1000)*selling_price,2)
      end;
      line_cost := case
        when coalesce(product_row.weight_price_unit,'kg')='grams'
          then round(qty_base*product_row.purchase_price_per_base_unit,2)
        else round((qty_base/1000)*product_row.purchase_price_per_base_unit,2)
      end;
    end if;

    if product_row.current_stock_base < qty_base then
      raise exception 'Insufficient stock for %', product_row.name;
    end if;

    line_profit := round(line_total-line_cost,2);
    if line_profit < 0
       and not coalesce((select allow_below_cost_sales from public.shop_settings where id=1),true)
    then
      raise exception 'Below-cost sales are disabled in shop settings';
    end if;

    total := total + line_total;
    total_cost := total_cost + line_cost;
    validated_lines := validated_lines || jsonb_build_array(jsonb_build_object(
      'product_id',product_id,'product_name',product_row.name,
      'quantity_base',qty_base,'quantity_display',qty_display,'sold_unit',sold_unit,
      'selling_price',selling_price,'purchase_price',product_row.purchase_price_per_base_unit,
      'total_sale',line_total,'total_cost',line_cost,'gross_profit',line_profit
    ));
  end loop;

  total := round(total,2);
  total_cost := round(total_cost,2);

  if p_payment_mode='cash' then
    cash_paid := total;
    upi_paid := 0;
    credit_paid := 0;
    actual_payment_mode := 'cash';
  elsif p_payment_mode='upi' then
    cash_paid := 0;
    upi_paid := total;
    credit_paid := 0;
    actual_payment_mode := 'upi';
  elsif p_payment_mode='split' then
    cash_paid := round(cash_paid,2);
    upi_paid := round(upi_paid,2);
    credit_paid := 0;
    if cash_paid+upi_paid<>total then
      raise exception 'Cash + UPI must equal the sale total';
    end if;
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
    cash_paid := round(cash_paid,2);
    upi_paid := round(upi_paid,2);
    credit_paid := round(credit_paid,2);
    if cash_paid+upi_paid+credit_paid<>total then
      raise exception 'Cash + UPI + Credit must equal the sale total';
    end if;
    actual_payment_mode := 'credit_split';
  end if;

  if actual_payment_mode in ('credit','credit_split') and credit_paid<=0 then
    raise exception 'Credit sales require a positive credit amount';
  end if;

  v_invoice := 'INV-' || to_char(now(),'YYYYMMDD') || '-' ||
    upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));

  insert into public.sale_transactions(
    shop_id,invoice_no,worker_id,creditor_id,subtotal,total,payment_mode,
    cash_amount,upi_amount,credit_amount,status
  )
  values(
    v_shop_id,v_invoice,p_worker_id,p_creditor_id,total,total,actual_payment_mode,
    round(cash_paid,2),round(upi_paid,2),round(credit_paid,2),'confirmed'
  )
  returning id into v_tx_id;

  -- Zero-priced lines remain in history but must not be the line that absorbs
  -- payment-rounding remainders. They therefore do not count as payable lines.
  select count(*) into line_count
  from jsonb_array_elements(validated_lines) x
  where (x->>'total_sale')::numeric > 0;
  remaining_total := total;
  remaining_cash := round(cash_paid,2);
  remaining_upi := round(upi_paid,2);
  remaining_credit := round(credit_paid,2);

  line_index := 0;
  for item in select value from jsonb_array_elements(validated_lines) loop
    product_id := (item->>'product_id')::uuid;
    select * into product_row
    from public.products
    where id=product_id and is_active=true;
    if not found then
      raise exception 'Product not found while persisting cart';
    end if;

    qty_base := (item->>'quantity_base')::numeric;
    qty_display := (item->>'quantity_display')::numeric;
    sold_unit := item->>'sold_unit';
    selling_price := (item->>'selling_price')::numeric;

    -- Re-evaluate the exact persisted values under the product lock. Keeping
    -- the weight-price branch here prevents the old kg-only persistence bug.
    if product_row.unit_type='piece' then
      line_total := round(qty_base*selling_price,2);
      line_cost := round(qty_base*product_row.purchase_price_per_base_unit,2);
    else
      line_total := case
        when coalesce(product_row.weight_price_unit,'kg')='grams'
          then round(qty_base*selling_price,2)
        else round((qty_base/1000)*selling_price,2)
      end;
      line_cost := case
        when coalesce(product_row.weight_price_unit,'kg')='grams'
          then round(qty_base*product_row.purchase_price_per_base_unit,2)
        else round((qty_base/1000)*product_row.purchase_price_per_base_unit,2)
      end;
    end if;
    line_profit := round(line_total-line_cost,2);

    if line_total is distinct from (item->>'total_sale')::numeric
       or line_cost is distinct from (item->>'total_cost')::numeric
       or line_profit is distinct from (item->>'gross_profit')::numeric
    then
      raise exception 'Cart line calculation changed while completing sale';
    end if;

    if line_total=0 then
      line_cash := 0;
      line_upi := 0;
      line_credit := 0;
    else
      line_index := line_index+1;
      if line_index=line_count then
      -- The last line absorbs all cent remainders. This makes the persisted
      -- line payment columns add up exactly to the cart history row.
        line_cash := round(remaining_cash,2);
        line_upi := round(remaining_upi,2);
        line_credit := round(remaining_credit,2);
      elsif actual_payment_mode='cash' then
        line_cash := line_total;
        line_upi := 0;
        line_credit := 0;
      elsif actual_payment_mode='upi' then
        line_cash := 0;
        line_upi := line_total;
        line_credit := 0;
      elsif actual_payment_mode='split' then
        -- Allocate one component and derive the other so each line remains
        -- exactly paid without creating a phantom credit amount.
        line_cash := round(remaining_cash*line_total/nullif(remaining_total,0),2);
        line_cash := least(greatest(line_cash,0),line_total);
        line_upi := round(line_total-line_cash,2);
        line_credit := 0;
      elsif actual_payment_mode='credit' then
        line_cash := 0;
        line_upi := 0;
        line_credit := line_total;
      else
        -- Credit-split allocation is sequential: cash is allocated first, then
        -- UPI from the remaining non-cash amount, and credit is the remainder.
        -- This avoids a negative line credit when two independently rounded
        -- percentages would exceed the line total.
        line_cash := round(remaining_cash*line_total/nullif(remaining_total,0),2);
        line_cash := least(greatest(line_cash,0),line_total);
        non_cash_remaining := remaining_upi+remaining_credit;
        if non_cash_remaining > 0 then
          line_upi := round(
            remaining_upi*(line_total-line_cash)/non_cash_remaining,
            2
          );
          line_upi := least(greatest(line_upi,0),line_total-line_cash);
        else
          line_upi := 0;
        end if;
        line_credit := round(line_total-line_cash-line_upi,2);
      end if;
    end if;

    if line_cash < 0 or line_upi < 0 or line_credit < 0
       or line_cash+line_upi+line_credit<>line_total
    then
      raise exception 'Unable to allocate cart payment amounts safely';
    end if;

    insert into public.sales(
      transaction_id,product_id,product_name_snapshot,worker_id,
      quantity_base,quantity_display,sold_unit,payment_mode,
      cash_amount,upi_amount,credit_amount,selling_price_per_base_unit,
      purchase_price_per_base_unit,total_sale,total_cost,gross_profit
    )
    values(
      v_tx_id,product_id,product_row.name,p_worker_id,
      qty_base,qty_display,sold_unit,actual_payment_mode,
      round(line_cash,2),round(line_upi,2),round(line_credit,2),selling_price,
      product_row.purchase_price_per_base_unit,round(line_total,2),
      round(line_cost,2),round(line_profit,2)
    );

    perform set_config('shop.allow_stock_change','on',true);
    update public.products
    set current_stock_base=current_stock_base-qty_base, updated_at=now()
    where id=product_id;
    perform set_config('shop.allow_stock_change','off',true);

    remaining_cash := round(remaining_cash-line_cash,2);
    remaining_upi := round(remaining_upi-line_upi,2);
    remaining_credit := round(remaining_credit-line_credit,2);
    remaining_total := round(remaining_total-line_total,2);
  end loop;

  if remaining_cash<>0 or remaining_upi<>0 or remaining_credit<>0
  then
    raise exception 'Cart payment allocation did not reconcile';
  end if;

  if actual_payment_mode in ('credit','credit_split') then
    insert into public.credit_ledger(
      shop_id,creditor_id,sale_transaction_id,sale_id,type,amount,
      payment_mode,cash_amount,upi_amount,worker_id,notes
    )
    values(
      v_shop_id,p_creditor_id,v_tx_id,null,'credit_sale',round(credit_paid,2),
      actual_payment_mode,0,0,p_worker_id,'Credit sale ' || v_invoice
    );
  end if;

  perform public.write_audit(
    'sale_created','sale_transaction',v_tx_id,
    jsonb_build_object(
      'invoice_no',v_invoice,
      'items',jsonb_array_length(p_items),
      'total',total,
      'cash_amount',cash_paid,
      'upi_amount',upi_paid,
      'credit_amount',credit_paid,
      'payment_mode',actual_payment_mode,
      'creditor_id',p_creditor_id
    )
  );

  return jsonb_build_object(
    'transaction_id',v_tx_id,
    'invoice_no',v_invoice,
    'total',total,
    'cash_amount',cash_paid,
    'upi_amount',upi_paid,
    'credit_amount',credit_paid,
    'payment_mode',actual_payment_mode
  );
end;
$$;

revoke all on function public.complete_cart_sale(uuid,jsonb,text,numeric,numeric,numeric,uuid)
  from public,anon;
grant execute on function public.complete_cart_sale(uuid,jsonb,text,numeric,numeric,numeric,uuid)
  to authenticated;

-- ============================================================
-- 3. Purchase-credit payments also update the debtor ledger
-- ============================================================

-- Five arguments provide a correct split-payment path for future callers.
-- The existing three-argument RPC below remains the compatibility path used
-- by the current app (cash and UPI payments have an unambiguous breakdown).
create or replace function public.pay_purchase_credit(
  p_purchase_id uuid,
  p_amount numeric,
  p_payment_mode text,
  p_cash_amount numeric,
  p_upi_amount numeric
)
returns public.inventory_purchases
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.inventory_purchases;
  v_shop text;
  v_amount numeric := round(coalesce(p_amount,0),2);
  v_cash numeric := round(coalesce(p_cash_amount,0),2);
  v_upi numeric := round(coalesce(p_upi_amount,0),2);
  v_mode text;
  v_debtor_id uuid;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;
  if v_amount <= 0 or v_amount::text in ('NaN','Infinity','-Infinity') then
    raise exception 'Payment amount must be positive';
  end if;
  if p_payment_mode is null or p_payment_mode not in ('cash','upi','split') then
    raise exception 'Invalid payment mode';
  end if;
  if v_cash<0 or v_upi<0
     or v_cash::text in ('NaN','Infinity','-Infinity')
     or v_upi::text in ('NaN','Infinity','-Infinity')
  then
    raise exception 'Invalid cash or UPI payment amount';
  end if;

  v_shop := (select shop_id from public.profiles where id=(select auth.uid()));
  -- Match pay_debtor()'s lock order: account first, then purchase. The first
  -- read only resolves the account; the purchase is re-read under a row lock.
  select i.debtor_id into v_debtor_id
  from public.inventory_purchases i
  join public.profiles p on p.id=i.purchased_by
  where i.id=p_purchase_id and p.shop_id=v_shop;
  if not found then
    raise exception 'Purchase not found';
  end if;
  if v_debtor_id is null then
    raise exception 'Purchase credit has no debtor';
  end if;
  perform 1 from public.debtors d
  where d.id=v_debtor_id and d.shop_id=v_shop
  for update;
  if not found then
    raise exception 'Debtor not found';
  end if;

  select i.* into r
  from public.inventory_purchases i
  join public.profiles p on p.id=i.purchased_by
  where i.id=p_purchase_id
    and p.shop_id=v_shop and i.debtor_id=v_debtor_id
  for update of i;

  if not found then
    raise exception 'Purchase not found';
  end if;
  if coalesce(r.pre_stock,false) then
    raise exception 'Pre-stock records cannot have purchase credit';
  end if;
  if v_amount > round(coalesce(r.credit_amount,0)-coalesce(r.credit_paid,0),2) then
    raise exception 'Payment exceeds purchase credit balance';
  end if;

  if p_payment_mode='cash' then
    if v_cash<>v_amount or v_upi<>0 then
      raise exception 'Cash payment must equal the payment amount';
    end if;
    v_mode := 'cash';
  elsif p_payment_mode='upi' then
    if v_cash<>0 or v_upi<>v_amount then
      raise exception 'UPI payment must equal the payment amount';
    end if;
    v_mode := 'upi';
  else
    if v_cash+v_upi<>v_amount then
      raise exception 'Cash + UPI must equal the payment amount';
    end if;
    v_mode := 'split';
  end if;

  update public.inventory_purchases
  set credit_paid=round(credit_paid+v_amount,2)
  where id=p_purchase_id
  returning * into r;

  insert into public.debtor_ledger(
    shop_id,debtor_id,purchase_id,type,amount,payment_mode,
    cash_amount,upi_amount,worker_id,notes
  )
  values(
    v_shop,r.debtor_id,p_purchase_id,'payment_made',v_amount,v_mode,
    v_cash,v_upi,(select auth.uid()),'Purchase credit payment'
  );

  perform public.write_audit(
    'purchase_credit_paid','inventory_purchase',p_purchase_id,
    jsonb_build_object(
      'amount',v_amount,
      'payment_mode',v_mode,
      'cash_amount',v_cash,
      'upi_amount',v_upi,
      'debtor_id',r.debtor_id
    )
  );

  return r;
end;
$$;

create or replace function public.pay_purchase_credit(
  p_purchase_id uuid,
  p_amount numeric,
  p_payment_mode text default 'cash'
)
returns public.inventory_purchases
language plpgsql
security definer
set search_path = ''
as $$
declare
  result_row public.inventory_purchases;
begin
  if p_payment_mode='cash' then
    select * into result_row
    from public.pay_purchase_credit(p_purchase_id,p_amount,p_payment_mode,p_amount,0);
  elsif p_payment_mode='upi' then
    select * into result_row
    from public.pay_purchase_credit(p_purchase_id,p_amount,p_payment_mode,0,p_amount);
  else
    raise exception 'Split purchase-credit payments require cash and UPI amounts';
  end if;
  return result_row;
end;
$$;

revoke all on function public.pay_purchase_credit(uuid,numeric,text,numeric,numeric)
  from public,anon;
grant execute on function public.pay_purchase_credit(uuid,numeric,text,numeric,numeric)
  to authenticated;
revoke all on function public.pay_purchase_credit(uuid,numeric,text)
  from public,anon;
grant execute on function public.pay_purchase_credit(uuid,numeric,text)
  to authenticated;

-- ============================================================
-- 4. Atomic cart-aware voiding with retained history
-- ============================================================

create or replace function public.void_cart_sale(
  p_transaction_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tx public.sale_transactions;
  line public.sales;
  product_row public.products;
  creditor_row public.creditors;
  ledger_row public.credit_ledger;
  v_shop text;
  v_line_count integer := 0;
  v_lines_voided integer := 0;
  v_stock_restored numeric := 0;
  v_credit_ledger_total numeric := 0;
  v_credit_reversed numeric := 0;
  v_credit_expected numeric := 0;
  v_credit_balance numeric := 0;
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;
  if btrim(coalesce(p_reason,''))='' then
    raise exception 'Correction reason is required';
  end if;

  v_shop := (select shop_id from public.profiles where id=(select auth.uid()));
  select * into tx
  from public.sale_transactions
  where id=p_transaction_id and shop_id=v_shop
  for update;

  if not found then
    raise exception 'Cart sale not found';
  end if;
  if tx.status<>'confirmed' then
    raise exception 'Cart sale is already voided';
  end if;

  select count(*) into v_line_count
  from public.sales
  where transaction_id=p_transaction_id;
  if v_line_count=0 then
    raise exception 'Cart sale has no retained lines and cannot be safely voided';
  end if;

  v_credit_expected := round(coalesce(tx.credit_amount,0),2);
  if v_credit_expected>0 then
    -- Match complete_cart_sale()/receive_credit_payment() lock ordering. This
    -- prevents a customer payment from racing the void balance check.
    select * into creditor_row
    from public.creditors
    where id=tx.creditor_id and shop_id=v_shop
    for update;
    if not found then
      raise exception 'Cart credit creditor not found';
    end if;
  end if;

  -- Lock and validate every line before changing any row. Product ids are
  -- ordered to keep concurrent voids deterministic. A deleted product cannot
  -- safely receive stock back, so the entire operation is rejected/rolled
  -- back rather than silently losing inventory.
  for line in
    select s.*
    from public.sales s
    where s.transaction_id=p_transaction_id
    order by s.product_id,s.id
    for update
  loop
    if line.voided then
      raise exception 'Cart sale contains an already-voided line';
    end if;
    if exists (
      select 1 from public.returns r
      where r.return_type='sale' and r.source_id=line.id
    ) then
      raise exception 'Cart sale has a sale return; reverse the return before voiding';
    end if;
    if line.product_id is null then
      raise exception 'Cart sale line no longer has a product to restore';
    end if;

    select * into product_row
    from public.products
    where id=line.product_id
    for update;
    if not found then
      raise exception 'Cart sale product no longer exists';
    end if;

    perform set_config('shop.allow_stock_change','on',true);
    update public.products
    set current_stock_base=current_stock_base+line.quantity_base,
        updated_at=now()
    where id=line.product_id;
    perform set_config('shop.allow_stock_change','off',true);

    update public.sales
    set voided=true,
        void_reason=btrim(p_reason),
        voided_at=now(),
        voided_by=(select auth.uid())
    where id=line.id;

    v_lines_voided := v_lines_voided+1;
    v_stock_restored := v_stock_restored+line.quantity_base;
  end loop;

  -- The migration persists the parent credit amount. Require the existing
  -- ledger effect to agree with it so an inconsistent historical cart cannot
  -- be voided into a second, incorrect balance adjustment.
  for ledger_row in
    select l.*
    from public.credit_ledger l
    where l.type='credit_sale'
      and (
        l.sale_transaction_id=p_transaction_id
        or l.sale_id in (
          select s.id from public.sales s
          where s.transaction_id=p_transaction_id
        )
      )
    order by l.id
    for update
  loop
    v_credit_ledger_total := round(v_credit_ledger_total+ledger_row.amount,2);
  end loop;

  if abs(v_credit_ledger_total-v_credit_expected)>0.01 then
    raise exception 'Cart credit ledger does not match sale history';
  end if;

  if v_credit_ledger_total>0 then
    if tx.creditor_id is null then
      raise exception 'Cart credit sale has no creditor';
    end if;
    v_credit_balance := public.creditor_balance(tx.creditor_id);
    if v_credit_balance < v_credit_ledger_total-0.01 then
      raise exception 'Cart credit has already been paid or adjusted; void is unsafe';
    end if;

    -- Keep the original credit_sale row and append one opposite-sign effect.
    -- payment_received/credit is explicitly supported by the ledger check
    -- above and by migration 005.
    for ledger_row in
      select l.*
      from public.credit_ledger l
      where l.type='credit_sale'
        and (
          l.sale_transaction_id=p_transaction_id
          or l.sale_id in (
            select s.id from public.sales s
            where s.transaction_id=p_transaction_id
          )
        )
      order by l.id
      for update
    loop
      insert into public.credit_ledger(
        shop_id,creditor_id,sale_transaction_id,sale_id,type,amount,
        payment_mode,cash_amount,upi_amount,worker_id,notes
      )
      values(
        ledger_row.shop_id,ledger_row.creditor_id,p_transaction_id,null,
        'payment_received',round(ledger_row.amount,2),'credit',0,0,
        (select auth.uid()),'Cart sale void reversal'
      );
      v_credit_reversed := round(v_credit_reversed+ledger_row.amount,2);
    end loop;
  end if;

  update public.sale_transactions
  set status='voided',
      void_reason=btrim(p_reason),
      voided_at=now(),
      voided_by=(select auth.uid())
  where id=p_transaction_id;

  perform public.write_audit(
    'sale_transaction_voided','sale_transaction',p_transaction_id,
    jsonb_build_object(
      'reason',btrim(p_reason),
      'lines_voided',v_lines_voided,
      'restored_quantity_base',v_stock_restored,
      'credit_reversed',v_credit_reversed
    )
  );

  return jsonb_build_object(
    'transaction_id',p_transaction_id,
    'status','voided',
    'lines_voided',v_lines_voided,
    'restored_quantity_base',v_stock_restored,
    'credit_reversed',v_credit_reversed
  );
end;
$$;

revoke all on function public.void_cart_sale(uuid,text) from public,anon;
grant execute on function public.void_cart_sale(uuid,text) to authenticated;

-- Keep the old line RPC for standalone record_sale() rows. If a line belongs
-- to a cart, route it through the transaction-level operation so callers
-- cannot void one line and leave the cart, stock, or credit balance half-open.
create or replace function public.void_sale(p_sale_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.sales;
  p public.products;
  v_shop text;
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;
  if btrim(coalesce(p_reason,''))='' then
    raise exception 'Correction reason is required';
  end if;

  v_shop := (select shop_id from public.profiles where id=(select auth.uid()));
  select * into s
  from public.sales sale_row
  where sale_row.id=p_sale_id
    and exists (
      select 1 from public.profiles w
      where w.id=sale_row.worker_id and w.shop_id=v_shop
    )
  for update;
  if not found then
    raise exception 'Sale not found';
  end if;
  if s.voided then
    raise exception 'Sale is already voided';
  end if;

  if s.transaction_id is not null then
    perform public.void_cart_sale(s.transaction_id,p_reason);
    return;
  end if;
  if exists (
    select 1 from public.returns r
    where r.return_type='sale' and r.source_id=s.id
  ) then
    raise exception 'Sale has a sale return; reverse the return before voiding';
  end if;
  if s.product_id is null then
    raise exception 'Sale product no longer exists';
  end if;

  select * into p from public.products where id=s.product_id for update;
  if not found then
    raise exception 'Sale product no longer exists';
  end if;

  update public.sales
  set voided=true,
      void_reason=btrim(p_reason),
      voided_at=now(),
      voided_by=(select auth.uid())
  where id=p_sale_id;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base+s.quantity_base,
      updated_at=now()
  where id=s.product_id;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit(
    'sale_voided','sale',s.id,
    jsonb_build_object('reason',btrim(p_reason),'restored_quantity_base',s.quantity_base)
  );
end;
$$;

revoke all on function public.void_sale(uuid,text) from public,anon;
grant execute on function public.void_sale(uuid,text) to authenticated;

-- Descriptive alias for integrations that address the parent explicitly.
create or replace function public.void_sale_transaction(
  p_transaction_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.void_cart_sale(p_transaction_id,p_reason);
end;
$$;

revoke all on function public.void_sale_transaction(uuid,text) from public,anon;
grant execute on function public.void_sale_transaction(uuid,text) to authenticated;

-- ============================================================
-- 5. Version marker and API reload
-- ============================================================

select pg_notify('pgrst','reload schema');

create table if not exists public.shop_management_schema_version(
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(8)
on conflict(version) do nothing;
