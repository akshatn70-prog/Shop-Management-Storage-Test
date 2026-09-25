-- Cart, multi-item bills, creditors, credit collections and worker price permission.
-- Additive migration: existing sales and record_sale remain compatible.
-- Run after the existing 20260925 migrations.

create extension if not exists pgcrypto;

alter table public.shop_settings
  add column if not exists workers_can_modify_selling_price boolean not null default false;

alter table public.sales
  add column if not exists transaction_id uuid;

alter table public.sales
  drop constraint if exists sales_payment_mode_check;

alter table public.sales
  add constraint sales_payment_mode_check
  check (payment_mode in ('cash','upi','split','credit','credit_split'));

alter table public.sales
  drop constraint if exists sales_payment_split_check;

alter table public.sales
  add constraint sales_payment_split_check
  check (
    (payment_mode='credit' and cash_amount=0 and upi_amount=0)
    or
    (payment_mode='credit_split' and cash_amount >= 0 and upi_amount >= 0 and (cash_amount + upi_amount) > 0 and (cash_amount + upi_amount) < total_sale)
    or
    (payment_mode in ('cash','upi','split') and cash_amount >= 0 and upi_amount >= 0 and abs((cash_amount + upi_amount) - total_sale) <= 0.01)
  );

create sequence if not exists public.shop_invoice_seq;

create table if not exists public.sale_transactions (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  invoice_no text not null unique,
  worker_id uuid not null references public.profiles(id),
  creditor_id uuid,
  subtotal numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  payment_mode text not null,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  status text not null default 'confirmed',
  created_at timestamptz not null default now(),
  constraint sale_transactions_payment_mode_check
    check (payment_mode in ('cash','upi','split','credit','credit_split')),
  constraint sale_transactions_amounts_check
    check (
      subtotal >= 0 and total >= 0 and cash_amount >= 0 and upi_amount >= 0
      and (
        (payment_mode='credit' and cash_amount=0 and upi_amount=0)
        or
        (payment_mode='credit_split' and cash_amount >= 0 and upi_amount >= 0 and (cash_amount + upi_amount) > 0 and (cash_amount + upi_amount) < total)
        or
        (payment_mode in ('cash','upi','split') and abs((cash_amount + upi_amount) - total) <= 0.01)
      )
    ),
  constraint sale_transactions_status_check
    check (status in ('confirmed','voided'))
);

alter table public.sale_transactions
  drop constraint if exists sale_transactions_payment_mode_check;
alter table public.sale_transactions
  add constraint sale_transactions_payment_mode_check
  check (payment_mode in ('cash','upi','split','credit','credit_split'));

alter table public.sale_transactions
  drop constraint if exists sale_transactions_amounts_check;
alter table public.sale_transactions
  add constraint sale_transactions_amounts_check
  check (
    subtotal >= 0 and total >= 0 and cash_amount >= 0 and upi_amount >= 0
    and (
      (payment_mode='credit' and cash_amount=0 and upi_amount=0)
      or
      (payment_mode='credit_split' and cash_amount >= 0 and upi_amount >= 0 and (cash_amount + upi_amount) > 0 and (cash_amount + upi_amount) < total)
      or
      (payment_mode in ('cash','upi','split') and abs((cash_amount + upi_amount) - total) <= 0.01)
    )
  );

create table if not exists public.creditors (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  name text not null,
  mobile text not null,
  mobile_normalized text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists creditors_shop_mobile_uidx
  on public.creditors(shop_id, mobile_normalized)
  where is_active = true and mobile_normalized <> '';

create index if not exists creditors_shop_name_idx on public.creditors(shop_id, lower(name));
create index if not exists creditors_shop_mobile_idx on public.creditors(shop_id, mobile_normalized);

alter table public.sale_transactions
  drop constraint if exists sale_transactions_creditor_id_fkey;

alter table public.sale_transactions
  add constraint sale_transactions_creditor_id_fkey
  foreign key (creditor_id) references public.creditors(id) on delete set null;

alter table public.sales
  drop constraint if exists sales_transaction_id_fkey;

alter table public.sales
  add constraint sales_transaction_id_fkey
  foreign key (transaction_id) references public.sale_transactions(id) on delete set null;

create index if not exists sales_transaction_id_idx on public.sales(transaction_id);
create index if not exists sale_transactions_shop_created_idx on public.sale_transactions(shop_id, created_at desc);
create index if not exists sale_transactions_worker_idx on public.sale_transactions(worker_id);
create index if not exists sale_transactions_creditor_idx on public.sale_transactions(creditor_id);

create table if not exists public.credit_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  creditor_id uuid not null references public.creditors(id),
  sale_transaction_id uuid references public.sale_transactions(id) on delete set null,
  sale_id uuid references public.sales(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  notes text,
  constraint credit_ledger_type_check
    check (type in ('credit_sale','payment_received','adjustment')),
  constraint credit_ledger_amount_check
    check (amount > 0),
  constraint credit_ledger_payment_check
    check (
      (type='credit_sale' and payment_mode in ('credit','credit_split') and cash_amount=0 and upi_amount=0)
      or
      (type='payment_received' and payment_mode in ('cash','upi','split') and cash_amount >= 0 and upi_amount >= 0 and abs((cash_amount + upi_amount) - amount) <= 0.01)
      or
      (type='adjustment')
    )
);

alter table public.credit_ledger
  drop constraint if exists credit_ledger_payment_check;
alter table public.credit_ledger
  add constraint credit_ledger_payment_check
  check (
    (type='credit_sale' and payment_mode in ('credit','credit_split') and cash_amount=0 and upi_amount=0)
    or
    (type='payment_received' and payment_mode in ('cash','upi','split') and cash_amount >= 0 and upi_amount >= 0 and abs((cash_amount + upi_amount) - amount) <= 0.01)
    or
    (type='adjustment')
  );

create index if not exists credit_ledger_creditor_created_idx
  on public.credit_ledger(creditor_id, created_at desc);
create index if not exists credit_ledger_shop_created_idx
  on public.credit_ledger(shop_id, created_at desc);
create index if not exists credit_ledger_sale_idx on public.credit_ledger(sale_id);

create or replace function public.normalize_creditor_mobile(p_mobile text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''), '[^0-9]', '', 'g') ~ '^91[0-9]{10}$'
      then right(regexp_replace(coalesce(p_mobile,''), '[^0-9]', '', 'g'), 10)
    else regexp_replace(coalesce(p_mobile,''), '[^0-9]', '', 'g')
  end
$$;

revoke execute on function public.normalize_creditor_mobile(text) from public, anon, authenticated;

create or replace function public.creditor_balance(p_creditor_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(
    case
      when type='credit_sale' then amount
      when type='payment_received' then -amount
      else amount
    end
  ),0)::numeric(14,2)
  from public.credit_ledger
  where creditor_id=p_creditor_id
    and shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
$$;

revoke execute on function public.creditor_balance(uuid) from public, anon;
grant execute on function public.creditor_balance(uuid) to authenticated;

create or replace function public.get_or_create_creditor(
  p_name text,
  p_mobile text
)
returns public.creditors
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_mobile text;
  result_row public.creditors;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;

  v_shop_id := (select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop_id is null or btrim(v_shop_id)='' then
    raise exception 'Shop ID is not configured';
  end if;

  v_mobile := public.normalize_creditor_mobile(p_mobile);
  if length(v_mobile) < 10 then
    raise exception 'Enter a valid mobile number';
  end if;
  if btrim(coalesce(p_name,''))='' then
    raise exception 'Creditor name is required';
  end if;

  insert into public.creditors(shop_id,name,mobile,mobile_normalized)
  values(v_shop_id,btrim(p_name),btrim(p_mobile),v_mobile)
  on conflict (shop_id,mobile_normalized) where is_active = true and mobile_normalized <> ''
  do update set
    name=excluded.name,
    mobile=excluded.mobile,
    updated_at=now()
  returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.get_or_create_creditor(text,text) from public, anon;
grant execute on function public.get_or_create_creditor(text,text) to authenticated;

-- Recreate the existing single-sale RPC with the worker selling-price permission.
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric);
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text);
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric);

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
language plpgsql
security definer
set search_path = ''
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
  is_owner_user boolean;
  can_change_price boolean;
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

  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_selling_price_per_base_unit < 0 then
    raise exception 'Invalid sale';
  end if;

  if p_payment_mode not in ('cash','upi','split') then
    raise exception 'Payment mode must be cash, upi or split';
  end if;

  select * into p
  from public.products
  where id=p_product_id and is_active=true
  for update;

  if not found then
    raise exception 'Product not found';
  end if;

  can_change_price := is_owner_user
    or coalesce((select workers_can_modify_selling_price from public.shop_settings where id=1),false);

  if not can_change_price
     and abs(p_selling_price_per_base_unit - p.selling_price_per_base_unit) > 0.000001 then
    raise exception 'Workers are not allowed to modify the selling price';
  end if;

  if p_selling_price_per_base_unit = 0
     and not coalesce((select allow_zero_price_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Zero-price sales are disabled in shop settings';
  end if;

  if p.unit_type='piece' then
    if p_quantity_base <> p_quantity_display
       or mod(p_quantity_base,1) <> 0
       or p_sold_unit <> 'piece' then
      raise exception 'Piece quantity must be a whole number and sold in pieces';
    end if;
  else
    if p_sold_unit not in ('grams','kg') then
      raise exception 'Weight products must be sold in grams or kg';
    end if;
    if p_sold_unit='kg' and p_quantity_base <> p_quantity_display*1000 then
      raise exception 'Invalid kg quantity';
    end if;
    if p_sold_unit='grams' and p_quantity_base <> p_quantity_display then
      raise exception 'Invalid gram quantity';
    end if;
  end if;

  if p.current_stock_base < p_quantity_base then
    raise exception 'Insufficient stock';
  end if;

  if p.unit_type='piece' then
    total_sale := p_quantity_base*p_selling_price_per_base_unit;
    total_cost := p_quantity_base*p.purchase_price_per_base_unit;
  else
    total_sale := (p_quantity_base/1000)*p_selling_price_per_base_unit;
    total_cost := (p_quantity_base/1000)*p.purchase_price_per_base_unit;
  end if;

  gross := total_sale-total_cost;

  if gross < 0
     and not coalesce((select allow_below_cost_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Below-cost sales are disabled in shop settings';
  end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then
      cash_paid:=total_sale; upi_paid:=0;
    elsif p_payment_mode='upi' then
      cash_paid:=0; upi_paid:=total_sale;
    else
      raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    cash_paid:=coalesce(p_cash_amount,0);
    upi_paid:=coalesce(p_upi_amount,0);
  end if;

  if cash_paid<0 or upi_paid<0 or abs((cash_paid+upi_paid)-total_sale)>0.01 then
    raise exception 'Cash + UPI must equal the sale total';
  end if;

  actual_payment_mode := case
    when cash_paid>0 and upi_paid>0 then 'split'
    when upi_paid>0 then 'upi'
    else 'cash'
  end;

  insert into public.sales(
    product_id,worker_id,quantity_base,quantity_display,sold_unit,payment_mode,
    cash_amount,upi_amount,selling_price_per_base_unit,purchase_price_per_base_unit,
    total_sale,total_cost,gross_profit
  )
  values(
    p_product_id,p_worker_id,p_quantity_base,p_quantity_display,p_sold_unit,actual_payment_mode,
    round(cash_paid,2),round(upi_paid,2),p_selling_price_per_base_unit,p.purchase_price_per_base_unit,
    round(total_sale,2),round(total_cost,2),round(gross,2)
  )
  returning * into result_row;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base-p_quantity_base, updated_at=now()
  where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit(
    'sale_created','sale',result_row.id,
    jsonb_build_object(
      'product_id',p_product_id,
      'quantity_base',p_quantity_base,
      'quantity_display',p_quantity_display,
      'sold_unit',p_sold_unit,
      'payment_mode',actual_payment_mode,
      'cash_amount',round(cash_paid,2),
      'upi_amount',round(upi_paid,2),
      'selling_price_per_base_unit',p_selling_price_per_base_unit,
      'total_sale',round(total_sale,2)
    )
  );

  return result_row;
end;
$$;

revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) from public, anon;
grant execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) to authenticated;

drop function if exists public.complete_cart_sale(uuid,jsonb,text,numeric,numeric,uuid);

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

  return jsonb_build_object(
    'transaction_id',v_tx_id,
    'invoice_no',v_invoice,
    'total',total,
    'payment_mode',actual_payment_mode
  );
end;
$$;

revoke execute on function public.complete_cart_sale(uuid,jsonb,text,numeric,numeric,numeric,uuid) from public, anon;
grant execute on function public.complete_cart_sale(uuid,jsonb,text,numeric,numeric,numeric,uuid) to authenticated;

create or replace function public.receive_credit_payment(
  p_creditor_id uuid,
  p_amount numeric,
  p_payment_mode text,
  p_cash_amount numeric default 0,
  p_upi_amount numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_creditor public.creditors;
  v_balance_before numeric;
  v_balance_after numeric;
  v_cash numeric := coalesce(p_cash_amount,0);
  v_upi numeric := coalesce(p_upi_amount,0);
  v_id uuid;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;

  v_shop_id := (select shop_id from public.profiles where id=(select auth.uid()));
  select * into v_creditor
  from public.creditors
  where id=p_creditor_id and shop_id=v_shop_id and is_active=true
  for update;

  if not found then
    raise exception 'Creditor not found';
  end if;
  if p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;
  if p_payment_mode not in ('cash','upi','split') then
    raise exception 'Invalid payment mode';
  end if;
  if v_cash < 0 or v_upi < 0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  v_balance_before := public.creditor_balance(p_creditor_id);
  if v_balance_before <= 0 then
    raise exception 'This creditor has no outstanding balance';
  end if;
  if p_amount > v_balance_before + 0.01 then
    raise exception 'Payment exceeds outstanding balance';
  end if;

  insert into public.credit_ledger(
    shop_id,creditor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  )
  values(
    v_shop_id,p_creditor_id,'payment_received',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Credit payment received'
  )
  returning id into v_id;

  v_balance_after := v_balance_before - p_amount;

  perform public.write_audit(
    'credit_payment_received','creditor',p_creditor_id,
    jsonb_build_object(
      'payment_id',v_id,
      'amount',round(p_amount,2),
      'payment_mode',p_payment_mode,
      'cash_amount',round(v_cash,2),
      'upi_amount',round(v_upi,2),
      'previous_balance',round(v_balance_before,2),
      'new_balance',round(v_balance_after,2)
    )
  );

  return jsonb_build_object(
    'payment_id',v_id,
    'previous_balance',round(v_balance_before,2),
    'new_balance',round(v_balance_after,2)
  );
end;
$$;

revoke execute on function public.receive_credit_payment(uuid,numeric,text,numeric,numeric) from public, anon;
grant execute on function public.receive_credit_payment(uuid,numeric,text,numeric,numeric) to authenticated;

-- Exposed tables are read-only to authenticated clients; all writes go through protected RPCs.
alter table public.sale_transactions enable row level security;
alter table public.creditors enable row level security;
alter table public.credit_ledger enable row level security;

revoke all on table public.sale_transactions, public.creditors, public.credit_ledger from anon, authenticated;
grant select on table public.sale_transactions, public.creditors, public.credit_ledger to authenticated;

drop policy if exists "sale transactions select shop" on public.sale_transactions;
create policy "sale transactions select shop"
on public.sale_transactions for select to authenticated
using (
  (select public.is_active_user())
  and shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
);

drop policy if exists "creditors select shop" on public.creditors;
create policy "creditors select shop"
on public.creditors for select to authenticated
using (
  (select public.is_active_user())
  and shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
);

drop policy if exists "credit ledger select shop" on public.credit_ledger;
create policy "credit ledger select shop"
on public.credit_ledger for select to authenticated
using (
  (select public.is_active_user())
  and shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
);

revoke insert, update, delete on public.sale_transactions from authenticated;
revoke insert, update, delete on public.creditors from authenticated;
revoke insert, update, delete on public.credit_ledger from authenticated;

do $$ begin
  alter publication supabase_realtime add table public.sale_transactions;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.creditors;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.credit_ledger;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- Keep the existing owner Clear All workflow consistent with the new transaction tables.
create or replace function public.clear_all_shop_data()
returns void
language plpgsql
security definer
set search_path = ''
as $clear_all$
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  -- Clear transactional/history data, but keep one permanent audit marker for this action.
  truncate table
    public.credit_ledger,
    public.sale_transactions,
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.daily_closings,
    public.sales,
    public.inventory_purchases,
    public.automatic_day_end_snapshots,
    public.audit_logs
    restart identity;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=0, updated_at=now()
  where id is not null;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit(
    'shop_data_cleared',
    'shop',
    null,
    jsonb_build_object('cleared_at',now())
  );
end;
$clear_all$;

revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;

create or replace function public.verify_cart_credit_schema()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  missing text[] := '{}';
begin
  if to_regclass('public.sale_transactions') is null then missing := array_append(missing,'sale_transactions'); end if;
  if to_regclass('public.creditors') is null then missing := array_append(missing,'creditors'); end if;
  if to_regclass('public.credit_ledger') is null then missing := array_append(missing,'credit_ledger'); end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='complete_cart_sale'
  ) then missing := array_append(missing,'complete_cart_sale'); end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='receive_credit_payment'
  ) then missing := array_append(missing,'receive_credit_payment'); end if;
  if not exists (
    select 1 from public.shop_settings where workers_can_modify_selling_price is not null
  ) then missing := array_append(missing,'workers_can_modify_selling_price'); end if;
  return jsonb_build_object('ok',cardinality(missing)=0,'missing',missing);
end;
$$;

revoke execute on function public.verify_cart_credit_schema() from public, anon;
grant execute on function public.verify_cart_credit_schema() to authenticated;
