-- SHOP MANAGEMENT — FINAL ALL-IN-ONE OWNER REGISTRATION SQL
-- This is the standalone fresh-Supabase setup.
-- Run the ENTIRE file once in a NEW Supabase project for one shop owner.
-- Do not run the migration-only FINAL_ALL_IN_ONE version from older commits.
--
-- This file contains:
-- 1. Base schema
-- 2. Auth/owner/worker setup
-- 3. Inventory, purchases, sales, daily closing and audit
-- 4. Security/RLS and protected RPCs
-- 5. Shop isolation
-- 6. Cart + multi-item sales
-- 7. Creditors + credit payments
-- 8. Daily summaries / Android Downloads support
--
-- The database generates a unique shop_id automatically for a fresh project.
-- No manual Shop ID replacement is required.
--
create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('owner','worker');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.product_unit as enum ('piece','weight');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.closing_status as enum ('draft','submitted','approved','locked');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.day_end_status as enum ('draft','submitted','confirmed','cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  role public.user_role not null default 'worker',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);


-- TEST REPAIR: debtor tables were referenced by the purchase/returns SQL but were missing.
create table if not exists public.debtors (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  name text not null,
  mobile text,
  address text,
  notes text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists debtors_shop_idx on public.debtors(shop_id);
create index if not exists debtors_active_idx on public.debtors(shop_id,is_active);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  unit_type public.product_unit not null,
  current_stock_base numeric(14,3) not null default 0 check (current_stock_base >= 0),
  purchase_price_per_base_unit numeric(12,2) not null default 0 check (purchase_price_per_base_unit >= 0),
  selling_price_per_base_unit numeric(12,2) not null default 0 check (selling_price_per_base_unit >= 0),
  low_stock_threshold_base numeric(14,3) not null default 0 check (low_stock_threshold_base >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_purchases (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null default 'Deleted product',
  quantity_base numeric(14,3) not null check (quantity_base > 0),
  quantity_display numeric(14,3) not null check (quantity_display > 0),
  purchase_unit text not null,
  purchase_price_per_base_unit numeric(12,2) not null check (purchase_price_per_base_unit >= 0),
  total_cost numeric(14,2) not null check (total_cost >= 0),
  purchased_by uuid not null references public.profiles(id),
  purchased_at timestamptz not null default now()
);

create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null default 'Deleted product',
  worker_id uuid not null references public.profiles(id),
  quantity_base numeric(14,3) not null check (quantity_base > 0),
  quantity_display numeric(14,3) not null check (quantity_display > 0),
  sold_unit text not null,
  payment_mode text not null default 'cash' check (payment_mode in ('cash','upi','split')),
  cash_amount numeric(14,2) not null default 0 check (cash_amount >= 0),
  upi_amount numeric(14,2) not null default 0 check (upi_amount >= 0),
  selling_price_per_base_unit numeric(12,2) not null check (selling_price_per_base_unit >= 0),
  purchase_price_per_base_unit numeric(12,2) not null check (purchase_price_per_base_unit >= 0),
  total_sale numeric(14,2) not null check (total_sale >= 0),
  total_cost numeric(14,2) not null check (total_cost >= 0),
  gross_profit numeric(14,2) not null,
  constraint sales_payment_split_check check (cash_amount + upi_amount = total_sale),
  voided boolean not null default false,
  void_reason text,
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  sold_at timestamptz not null default now()
);


-- TEST REPAIR: debtor ledger used by credit purchases/payments.
create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null default 0 check (amount >= 0),
  payment_mode text not null default 'credit',
  cash_amount numeric(14,2) not null default 0 check (cash_amount >= 0),
  upi_amount numeric(14,2) not null default 0 check (upi_amount >= 0),
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists debtor_ledger_shop_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_idx on public.debtor_ledger(debtor_id,created_at desc);

create table if not exists public.daily_closings (
  id uuid primary key default gen_random_uuid(),
  business_date date not null,
  worker_id uuid not null references public.profiles(id),
  expected_total numeric(14,2) not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  difference numeric(14,2) generated always as ((cash_amount + upi_amount) - expected_total) stored,
  status public.closing_status not null default 'draft',
  submitted_at timestamptz,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id),
  locked_at timestamptz,
  unique (business_date, worker_id)
);

create table if not exists public.day_end_summaries (
  id uuid primary key default gen_random_uuid(),
  business_date date not null,
  worker_id uuid not null references public.profiles(id),
  notes text not null default '',
  expected_total numeric(14,2) not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  status public.day_end_status not null default 'draft',
  submitted_at timestamptz,
  confirmed_at timestamptz,
  confirmed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (business_date, worker_id)
);
alter table public.sales
  add column if not exists payment_mode text not null default 'cash',
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.daily_closings
  add column if not exists expected_total numeric(14,2) not null default 0,
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.day_end_summaries
  add column if not exists expected_total numeric(14,2) not null default 0,
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.day_end_summaries
  drop constraint if exists day_end_payment_split_check;
alter table public.day_end_summaries
  add constraint day_end_payment_split_check
  check (expected_total >= 0 and cash_amount >= 0 and upi_amount >= 0 and cash_amount + upi_amount = expected_total);

create table if not exists public.day_end_summary_lines (
  id uuid primary key default gen_random_uuid(),
  summary_id uuid not null references public.day_end_summaries(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null default 'Deleted product',
  quantity_base numeric(14,3) not null check (quantity_base > 0),
  quantity_display numeric(14,3) not null check (quantity_display > 0),
  sold_unit text not null,
  selling_price_per_base_unit numeric(12,2) not null check (selling_price_per_base_unit >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.shop_settings (
  id integer primary key default 1 check (id = 1),
  shop_name text not null default 'My Shop',
  currency text not null default 'INR',
  timezone text not null default 'Asia/Kolkata',
  dashboard_reset_time text not null default '00:00'
    check (dashboard_reset_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  allow_below_cost_sales boolean not null default true,
  allow_zero_price_sales boolean not null default true,
  shop_id text,
  updated_at timestamptz not null default now()
);

insert into public.shop_settings(id)
values (1)
on conflict (id) do nothing;

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists products_active_idx on public.products(is_active);
create index if not exists purchases_product_idx on public.inventory_purchases(product_id);
create index if not exists purchases_date_idx on public.inventory_purchases(purchased_at);
create index if not exists sales_sold_at_idx on public.sales(sold_at);
create index if not exists sales_worker_idx on public.sales(worker_id);
create index if not exists sales_product_idx on public.sales(product_id);
create index if not exists sales_voided_idx on public.sales(voided);
create index if not exists sales_payment_mode_idx on public.sales(payment_mode);
create index if not exists closing_date_idx on public.daily_closings(business_date);
create index if not exists day_end_date_idx on public.day_end_summaries(business_date);
create index if not exists day_end_worker_idx on public.day_end_summaries(worker_id);
create index if not exists audit_created_idx on public.audit_logs(created_at);
create index if not exists audit_actor_idx on public.audit_logs(actor_id);

create or replace function public.is_owner()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists(
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'owner' and is_active = true
  );
$$;

revoke execute on function public.is_owner() from public, anon;
grant execute on function public.is_owner() to authenticated;

create or replace function public.is_active_user()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists(
    select 1 from public.profiles
    where id = (select auth.uid()) and is_active = true
  );
$$;

revoke execute on function public.is_active_user() from public, anon;
grant execute on function public.is_active_user() to authenticated;

create or replace function public.refresh_automatic_day_end_snapshot(p_business_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare tz text; product_json jsonb; worker_json jsonb;
begin
  select timezone into tz from public.shop_settings where id=1;
  select coalesce(jsonb_agg(x order by x->>'product'), '[]'::jsonb) into product_json
  from (
    select jsonb_build_object(
      'product',coalesce(p.name,'Unknown'),
      'quantity_base',sum(s.quantity_base),
      'revenue',round(sum(s.total_sale),2),
      'profit',round(sum(s.gross_profit),2)
    ) x
    from public.sales s left join public.products p on p.id=s.product_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(p.name,'Unknown')
  ) q;
  select coalesce(jsonb_agg(x order by x->>'worker'), '[]'::jsonb) into worker_json
  from (
    select jsonb_build_object(
      'worker',coalesce(pr.full_name,'Worker'),
      'transactions',count(*),
      'revenue',round(sum(s.total_sale),2),
      'profit',round(sum(s.gross_profit),2),
      'cash',round(sum(s.cash_amount),2),
      'upi',round(sum(s.upi_amount),2)
    ) x
    from public.sales s left join public.profiles pr on pr.id=s.worker_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(pr.full_name,'Worker')
  ) q;
  insert into public.automatic_day_end_snapshots(
    business_date,total_sales,total_cost,total_profit,transactions,cash_amount,upi_amount,product_breakdown,worker_breakdown,updated_at
  )
  select p_business_date,coalesce(sum(s.total_sale),0),coalesce(sum(s.total_cost),0),coalesce(sum(s.gross_profit),0),
         count(*),coalesce(sum(s.cash_amount),0),coalesce(sum(s.upi_amount),0),coalesce(product_json,'[]'::jsonb),coalesce(worker_json,'[]'::jsonb),now()
  from public.sales s
  where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
  on conflict (business_date) do update set
    total_sales=excluded.total_sales,total_cost=excluded.total_cost,total_profit=excluded.total_profit,
    transactions=excluded.transactions,cash_amount=excluded.cash_amount,upi_amount=excluded.upi_amount,
    product_breakdown=excluded.product_breakdown,worker_breakdown=excluded.worker_breakdown,updated_at=now();
end;
$$;
revoke execute on function public.refresh_automatic_day_end_snapshot(date) from public,anon,authenticated;

create or replace function public.refresh_automatic_day_end_snapshot_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  tz text;
  d date;
begin
  select s.timezone
    into tz
  from public.shop_settings s
  where s.id = 1;

  d := (
    coalesce(NEW.sold_at, OLD.sold_at)
    AT TIME ZONE (COALESCE(tz, 'Asia/Kolkata'))
  )::date;

  perform public.refresh_automatic_day_end_snapshot(d);
  return coalesce(NEW, OLD);
end;
$$;

revoke execute on function public.refresh_automatic_day_end_snapshot_trigger()
from public, anon, authenticated;

drop trigger if exists sales_refresh_automatic_day_end_snapshot
on public.sales;

create trigger sales_refresh_automatic_day_end_snapshot
after insert or update of voided
on public.sales
for each row
execute function public.refresh_automatic_day_end_snapshot_trigger();


create or replace function public.write_audit(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_details jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values((select auth.uid()),p_action,p_entity_type,p_entity_id,coalesce(p_details,'{}'::jsonb));
end;
$$;

revoke execute on function public.write_audit(text,text,uuid,jsonb) from public, anon;
grant execute on function public.write_audit(text,text,uuid,jsonb) to authenticated;

create or replace function public.create_product(
  p_name text,
  p_unit_type public.product_unit,
  p_opening_stock_base numeric,
  p_purchase_price numeric,
  p_selling_price numeric,
  p_low_stock_threshold_base numeric
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_id uuid;
  opening_cost numeric;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if trim(coalesce(p_name,'')) = '' or p_opening_stock_base < 0 or p_purchase_price < 0 or p_selling_price < 0 or p_low_stock_threshold_base < 0 then
    raise exception 'Invalid product';
  end if;
  if p_unit_type = 'piece' and mod(p_opening_stock_base, 1) <> 0 then
    raise exception 'Piece stock must be a whole number';
  end if;

  insert into public.products(
    name, unit_type, current_stock_base, purchase_price_per_base_unit,
    selling_price_per_base_unit, low_stock_threshold_base, is_active
  ) values (
    trim(p_name), p_unit_type, 0, p_purchase_price,
    p_selling_price, p_low_stock_threshold_base, true
  ) returning id into new_id;

  if p_opening_stock_base > 0 then
    if p_unit_type = 'weight' then
      opening_cost := (p_opening_stock_base / 1000) * p_purchase_price;
    else
      opening_cost := p_opening_stock_base * p_purchase_price;
    end if;
    insert into public.inventory_purchases(
      product_id, product_name_snapshot, quantity_base, quantity_display, purchase_unit,
      purchase_price_per_base_unit, total_cost, purchased_by
    ) values (
      new_id, trim(p_name), p_opening_stock_base,
      case when p_unit_type = 'weight' then p_opening_stock_base / 1000 else p_opening_stock_base end,
      case when p_unit_type = 'weight' then 'kg' else 'piece' end,
      p_purchase_price, opening_cost, (select auth.uid())
    );
    perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=p_opening_stock_base, updated_at=now() where id=new_id;
  perform set_config('shop.allow_stock_change','off',true);
  end if;

  perform public.write_audit('product_created','product',new_id,
    jsonb_build_object('opening_stock_base',p_opening_stock_base,'purchase_price',p_purchase_price,'selling_price',p_selling_price));
  return new_id;
end;
$$;

revoke execute on function public.create_product(text,public.product_unit,numeric,numeric,numeric,numeric) from public, anon;
grant execute on function public.create_product(text,public.product_unit,numeric,numeric,numeric,numeric) to authenticated;

grant execute on function public.create_product(text,public.product_unit,numeric,numeric,numeric,numeric) to authenticated;

create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_old jsonb := case when TG_OP <> 'INSERT' then to_jsonb(OLD) else '{}'::jsonb end;
  v_new jsonb := case when TG_OP <> 'DELETE' then to_jsonb(NEW) else '{}'::jsonb end;
  v_entity_id uuid;
begin
  -- Do not assume every audited table has a name column.
  -- The previous version accessed OLD.name directly, which crashes when
  -- profiles/shop_settings are updated because those records have no name field.
  -- Use the row JSON only, so this trigger is safe for every audited table.
  if TG_TABLE_NAME = 'products'
     and TG_OP = 'UPDATE'
     and v_old->>'name' is not distinct from v_new->>'name'
     and v_old->>'purchase_price_per_base_unit' is not distinct from v_new->>'purchase_price_per_base_unit'
     and v_old->>'selling_price_per_base_unit' is not distinct from v_new->>'selling_price_per_base_unit'
     and v_old->>'low_stock_threshold_base' is not distinct from v_new->>'low_stock_threshold_base'
     and v_old->>'is_active' is not distinct from v_new->>'is_active'
  then
    return NEW;
  end if;

  begin
    if TG_OP = 'DELETE' then
      v_entity_id := (v_old->>'id')::uuid;
    else
      v_entity_id := (v_new->>'id')::uuid;
    end if;
  exception when others then
    v_entity_id := null;
  end;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(
    (select auth.uid()),
    lower(TG_OP),
    TG_TABLE_NAME,
    v_entity_id,
    jsonb_build_object('new',v_new,'old',v_old)
  );

  if TG_OP = 'DELETE' then return OLD; end if;
  return NEW;
end;
$$;

revoke execute on function public.audit_row_change() from public, anon, authenticated;

drop trigger if exists audit_products on public.products;
create trigger audit_products after insert or update or delete on public.products
for each row execute function public.audit_row_change();

drop trigger if exists audit_profiles on public.profiles;
create trigger audit_profiles after update on public.profiles
for each row execute function public.audit_row_change();

drop trigger if exists audit_settings on public.shop_settings;
create trigger audit_settings after update on public.shop_settings
for each row execute function public.audit_row_change();

drop trigger if exists audit_closings on public.daily_closings;
create trigger audit_closings after insert or update on public.daily_closings
for each row execute function public.audit_row_change();

drop trigger if exists audit_day_end on public.day_end_summaries;
create trigger audit_day_end after insert or update on public.day_end_summaries
for each row execute function public.audit_row_change();

drop function if exists public.add_inventory_purchase(uuid,numeric,numeric,text,numeric);
drop function if exists public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text);
drop function if exists public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text,numeric);

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
  return v_id;
end;
$purchase$;

revoke all on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text,numeric) from public,anon;
grant execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text,numeric) to authenticated;

drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric);
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
  return result_row;
end;
$$;

revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) from public, anon;

create or replace function public.void_sale(p_sale_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sales;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if trim(coalesce(p_reason,'')) = '' then raise exception 'Correction reason is required'; end if;

  select * into s from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if s.voided then raise exception 'Sale is already voided'; end if;

  update public.sales
  set voided=true, void_reason=trim(p_reason), voided_at=now(), voided_by=(select auth.uid())
  where id=p_sale_id;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base+s.quantity_base, updated_at=now()
  where id=s.product_id;
  perform set_config('shop.allow_stock_change','off',true);

  perform public.write_audit('sale_voided','sale',s.id,
    jsonb_build_object('reason',trim(p_reason),'restored_quantity_base',s.quantity_base));
end;
$$;

create or replace function public.normalize_day_end_line()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  p public.products;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  select * into p from public.products where id=NEW.product_id and is_active=true;
  if not found then raise exception 'Product not found or inactive'; end if;
  if NEW.quantity_display <= 0 then raise exception 'Invalid day-end quantity'; end if;
  if p.unit_type='piece' then
    if NEW.sold_unit <> 'piece' or mod(NEW.quantity_display,1) <> 0 then raise exception 'Piece quantity must be a whole number'; end if;
    NEW.quantity_base := NEW.quantity_display;
  else
    if NEW.sold_unit not in ('grams','kg') then raise exception 'Weight unit must be grams or kg'; end if;
    NEW.quantity_base := case when NEW.sold_unit='kg' then NEW.quantity_display*1000 else NEW.quantity_display end;
  end if;
  NEW.selling_price_per_base_unit := p.selling_price_per_base_unit;
  return NEW;
end;
$$;

revoke execute on function public.normalize_day_end_line() from public, anon, authenticated;

drop trigger if exists normalize_day_end_line on public.day_end_summary_lines;
create trigger normalize_day_end_line
before insert on public.day_end_summary_lines
for each row execute function public.normalize_day_end_line();

create or replace function public.submit_day_end_summary(p_summary_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.day_end_summaries;
  total_expected numeric(14,2);
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  select * into s from public.day_end_summaries where id=p_summary_id for update;
  if not found or (s.worker_id <> (select auth.uid()) and not (select public.is_owner())) then raise exception 'Summary not found or unauthorized'; end if;
  if s.status <> 'draft' then raise exception 'Summary is not editable'; end if;

  select coalesce(sum(
    case
      when l.sold_unit='kg' then l.quantity_display*l.selling_price_per_base_unit
      when l.sold_unit='grams' then (l.quantity_display/1000)*l.selling_price_per_base_unit
      else l.quantity_display*l.selling_price_per_base_unit
    end
  ),0) into total_expected
  from public.day_end_summary_lines l where l.summary_id=p_summary_id;

  if total_expected <= 0 then raise exception 'Summary must contain at least one sale'; end if;
  if s.cash_amount < 0 or s.upi_amount < 0 then raise exception 'Cash and UPI cannot be negative'; end if;
  if abs((s.cash_amount+s.upi_amount)-total_expected)>0.01 then raise exception 'Cash + UPI must equal the day-end total of %',round(total_expected,2); end if;

  update public.day_end_summaries
  set status='submitted', expected_total=round(total_expected,2), submitted_at=now()
  where id=p_summary_id;

  insert into public.daily_closings(business_date,worker_id,expected_total,cash_amount,upi_amount,status,submitted_at)
  values(s.business_date,s.worker_id,round(total_expected,2),round(s.cash_amount,2),round(s.upi_amount,2),'submitted',now())
  on conflict (business_date,worker_id) do update
  set expected_total=excluded.expected_total,cash_amount=excluded.cash_amount,upi_amount=excluded.upi_amount,
      status=case when public.daily_closings.status in ('approved','locked') then public.daily_closings.status else 'submitted' end,
      submitted_at=case when public.daily_closings.status in ('approved','locked') then public.daily_closings.submitted_at else excluded.submitted_at end;

  perform public.write_audit('day_end_submitted','day_end_summary',p_summary_id,
    jsonb_build_object('expected_total',round(total_expected,2),'cash_amount',round(s.cash_amount,2),'upi_amount',round(s.upi_amount,2)));
end;
$$;

create or replace function public.confirm_day_end_summary(p_summary_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.day_end_summaries;
  l record;
  line_total numeric;
  remaining_cash numeric;
  remaining_upi numeric;
  line_cash numeric;
  line_upi numeric;
  line_index integer:=0;
  line_count integer;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  select * into s from public.day_end_summaries where id=p_summary_id for update;
  if not found or s.status<>'submitted' then raise exception 'Summary not submitted'; end if;
  select count(*) into line_count from public.day_end_summary_lines where summary_id=p_summary_id;
  remaining_cash:=s.cash_amount; remaining_upi:=s.upi_amount;

  for l in select * from public.day_end_summary_lines where summary_id=p_summary_id order by created_at loop
    line_index:=line_index+1;
    if l.sold_unit='kg' then line_total:=l.quantity_display*l.selling_price_per_base_unit;
    elsif l.sold_unit='grams' then line_total:=(l.quantity_display/1000)*l.selling_price_per_base_unit;
    else line_total:=l.quantity_display*l.selling_price_per_base_unit; end if;

    if line_index=line_count then
      line_cash:=remaining_cash; line_upi:=remaining_upi;
    else
      line_cash:=round(s.cash_amount*line_total/nullif(s.expected_total,0),2);
      line_upi:=round(s.upi_amount*line_total/nullif(s.expected_total,0),2);
      remaining_cash:=remaining_cash-line_cash; remaining_upi:=remaining_upi-line_upi;
    end if;

    perform public.record_sale(
      l.product_id,s.worker_id,l.quantity_base,l.quantity_display,l.sold_unit,l.selling_price_per_base_unit,
      case when line_cash>0 and line_upi>0 then 'split' when line_upi>0 then 'upi' else 'cash' end,
      line_cash,line_upi
    );
  end loop;

  update public.day_end_summaries set status='confirmed',confirmed_at=now(),confirmed_by=(select auth.uid()) where id=p_summary_id;
  update public.daily_closings set expected_total=s.expected_total,cash_amount=s.cash_amount,upi_amount=s.upi_amount
    where business_date=s.business_date and worker_id=s.worker_id;
  perform public.write_audit('day_end_confirmed','day_end_summary',p_summary_id,
    jsonb_build_object('expected_total',s.expected_total,'cash_amount',s.cash_amount,'upi_amount',s.upi_amount));
end;
$$;

create or replace function public.submit_daily_closing(
  p_business_date date,
  p_cash numeric,
  p_upi numeric,
  p_closing_id uuid default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  closing_id uuid;
  expected numeric;
  current_status public.closing_status;
  shop_tz text;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if not exists (select 1 from public.profiles where id=(select auth.uid()) and role='worker' and is_active=true) then
    raise exception 'Only an active worker can submit a closing';
  end if;
  if p_cash < 0 or p_upi < 0 then raise exception 'Cash and UPI cannot be negative'; end if;

  select timezone into shop_tz from public.shop_settings where id=1;
  select coalesce(sum(s.total_sale),0) into expected
  from public.sales s
  where s.worker_id=(select auth.uid())
    and s.voided=false
    and (s.sold_at at time zone coalesce(shop_tz,'Asia/Kolkata'))::date=p_business_date;

  if p_closing_id is not null then
    select id,status into closing_id,current_status
    from public.daily_closings
    where id=p_closing_id and worker_id=(select auth.uid())
    for update;
    if closing_id is null then raise exception 'Closing not found'; end if;
    if current_status in ('approved','locked') then raise exception 'Closing is already finalized'; end if;
    update public.daily_closings
    set business_date=p_business_date, expected_total=expected,
        cash_amount=p_cash, upi_amount=p_upi,
        status='submitted', submitted_at=now()
    where id=closing_id;
  else
    select id,status into closing_id,current_status
    from public.daily_closings
    where worker_id=(select auth.uid()) and business_date=p_business_date
    for update;
    if closing_id is not null and current_status in ('approved','locked') then
      raise exception 'Closing is already finalized';
    end if;
    if closing_id is null then
      insert into public.daily_closings(
        worker_id,business_date,expected_total,cash_amount,upi_amount,status,submitted_at
      ) values(
        (select auth.uid()),p_business_date,expected,p_cash,p_upi,'submitted',now()
      ) returning id into closing_id;
    else
      update public.daily_closings
      set expected_total=expected,cash_amount=p_cash,upi_amount=p_upi,status='submitted',submitted_at=now()
      where id=closing_id;
    end if;
  end if;

  perform public.write_audit('closing_submitted','daily_closing',closing_id,
    jsonb_build_object('business_date',p_business_date,'expected_total',expected,'cash',p_cash,'upi',p_upi));
  return closing_id;
end;
$$;

revoke execute on function public.submit_daily_closing(date,numeric,numeric,uuid) from public, anon;
grant execute on function public.submit_daily_closing(date,numeric,numeric,uuid) to authenticated;

create or replace function public.approve_closing(p_closing_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  update public.daily_closings
  set status='approved', approved_at=now(), approved_by=(select auth.uid())
  where id=p_closing_id and status='submitted';

  if not found then raise exception 'Closing not found or not submitted'; end if;

  perform public.write_audit('closing_approved','daily_closing',p_closing_id);
end;
$$;

create or replace function public.lock_closing(p_closing_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  update public.daily_closings
  set status='locked', locked_at=now()
  where id=p_closing_id and status='approved';

  if not found then raise exception 'Closing must be approved before locking'; end if;

  perform public.write_audit('closing_locked','daily_closing',p_closing_id);
end;
$$;

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

  -- Use TRUNCATE instead of DELETE so pg_safeupdate / WHERE enforcement
  -- cannot reject the clear operation. All transaction tables and their
  -- dependent ledger/summary tables are explicitly included.
  truncate table
    public.debtor_ledger,
    public.credit_ledger,
    public.sale_transactions,
    public.sales,
    public.inventory_purchases,
    public.daily_closings,
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.automatic_day_end_snapshots,
    public.daily_financial_summaries,
    public.lifetime_financial_summaries,
    public.creditor_daily_financial_aggregates,
    public.returns,
    public.audit_logs
    restart identity;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base = 0,
      updated_at = now()
  where id is not null;

  perform set_config('shop.allow_stock_change','off',true);

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    details
  )
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object('cleared_at',now())
  );
end;
$clear_all$;

revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;

create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.products;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  select * into p from public.products where id=p_product_id for update;
  if not found then raise exception 'Product not found'; end if;
  delete from public.products where id=p_product_id;
end;
$$;
revoke execute on function public.delete_product(uuid) from public, anon;
grant execute on function public.delete_product(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.inventory_purchases enable row level security;
alter table public.sales enable row level security;
alter table public.daily_closings enable row level security;
alter table public.day_end_summaries enable row level security;
alter table public.day_end_summary_lines enable row level security;
alter table public.shop_settings enable row level security;
alter table public.audit_logs enable row level security;
alter table public.automatic_day_end_snapshots enable row level security;

drop policy if exists "profiles self or owner" on public.profiles;
create policy "profiles self or owner" on public.profiles for select to authenticated
using (
  id=(select auth.uid())
  or ((select public.is_active_user()) and (select public.is_owner()))
);

create or replace function public.protect_last_owner()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if OLD.role='owner' and OLD.is_active=true
     and (NEW.role<>'owner' or NEW.is_active=false)
     and not exists (
       select 1 from public.profiles p
       where p.id<>OLD.id and p.role='owner' and p.is_active=true
     )
  then
    raise exception 'At least one active owner is required';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.protect_last_owner() from public, anon, authenticated;
drop trigger if exists protect_last_owner on public.profiles;
create trigger protect_last_owner before update on public.profiles
for each row execute function public.protect_last_owner();

drop policy if exists "owner update profiles" on public.profiles;
create policy "owner update profiles" on public.profiles for update to authenticated
using ((select public.is_owner())) with check ((select public.is_owner()));

drop policy if exists "authenticated read active products" on public.products;
create policy "authenticated read active products" on public.products for select to authenticated
using ((select public.is_active_user()) and (is_active=true or (select public.is_owner())));

create or replace function public.protect_product_stock_direct_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if OLD.current_stock_base is distinct from NEW.current_stock_base
     and current_setting('shop.allow_stock_change', true) is distinct from 'on'
  then
    raise exception 'Stock can only change through sale, purchase, correction or reset operations';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.protect_product_stock_direct_update() from public, anon, authenticated;
drop trigger if exists protect_product_stock_direct_update on public.products;create trigger protect_product_stock_direct_update before update on public.products
for each row execute function public.protect_product_stock_direct_update();

drop policy if exists "owner update products" on public.products;
create policy "owner update products" on public.products for update to authenticated
using ((select public.is_owner())) with check ((select public.is_owner()));

drop policy if exists "owner purchases read" on public.inventory_purchases;
create policy "owner purchases read" on public.inventory_purchases for select to authenticated
using ((select public.is_active_user()) and ((select public.is_owner()) or purchased_by=(select auth.uid())));

drop policy if exists "owner purchases insert" on public.inventory_purchases;

drop policy if exists "sales read" on public.sales;
create policy "sales read" on public.sales for select to authenticated
using ((select public.is_active_user()) and ((select public.is_owner()) or worker_id=(select auth.uid())));

drop policy if exists "sales insert blocked direct" on public.sales;
create policy "sales insert blocked direct" on public.sales for insert to authenticated with check (false);

drop policy if exists "sales update blocked direct" on public.sales;
create policy "sales update blocked direct" on public.sales for update to authenticated using (false);

drop policy if exists "sales delete blocked" on public.sales;
create policy "sales delete blocked" on public.sales for delete to authenticated using (false);

drop policy if exists "closing read" on public.daily_closings;
create policy "closing read" on public.daily_closings for select to authenticated
using ((select public.is_active_user()) and ((select public.is_owner()) or worker_id=(select auth.uid())));

drop policy if exists "day end read" on public.day_end_summaries;
create policy "day end read" on public.day_end_summaries for select to authenticated
using ((select public.is_active_user()) and ((select public.is_owner()) or worker_id=(select auth.uid())));

drop policy if exists "day end insert own" on public.day_end_summaries;
drop policy if exists "day end insert own or owner" on public.day_end_summaries;
create policy "day end insert own or owner" on public.day_end_summaries for insert to authenticated
with check ((select public.is_active_user()) and (worker_id=(select auth.uid()) or (select public.is_owner())));

drop policy if exists "day end update draft" on public.day_end_summaries;
create policy "day end update draft" on public.day_end_summaries for update to authenticated
using (worker_id=(select auth.uid()) and status='draft')
with check ((select public.is_active_user()) and worker_id=(select auth.uid()) and status='draft');

drop policy if exists "day end lines read" on public.day_end_summary_lines;
create policy "day end lines read" on public.day_end_summary_lines for select to authenticated
using (
  exists (
    select 1 from public.day_end_summaries s
    where s.id=summary_id and (select public.is_active_user()) and ((select public.is_owner()) or s.worker_id=(select auth.uid()))
  )
);

drop policy if exists "day end lines insert draft" on public.day_end_summary_lines;
create policy "day end lines insert draft" on public.day_end_summary_lines for insert to authenticated
with check (
  exists (
    select 1 from public.day_end_summaries s
    where s.id=summary_id and (select public.is_active_user()) and ((s.worker_id=(select auth.uid())) or (select public.is_owner())) and s.status='draft'
  )
);

drop policy if exists "settings read" on public.shop_settings;
create policy "settings read" on public.shop_settings for select to authenticated using ((select public.is_active_user()));

drop policy if exists "settings owner update" on public.shop_settings;
create policy "settings owner update" on public.shop_settings for update to authenticated
using ((select public.is_owner())) with check ((select public.is_owner()));

drop policy if exists "audit read owner" on public.audit_logs;
create policy "audit read owner" on public.audit_logs for select to authenticated
using ((select public.is_owner()));

revoke all on table public.profiles from anon;
revoke all on table public.products from anon;
revoke all on table public.inventory_purchases from anon;
revoke all on table public.sales from anon;
revoke all on table public.daily_closings from anon;
revoke all on table public.day_end_summaries from anon;
revoke all on table public.day_end_summary_lines from anon;
revoke all on table public.shop_settings from anon;
revoke all on table public.audit_logs from anon;

grant select, update on public.profiles to authenticated;
grant select, update on public.products to authenticated;
revoke delete on public.products from authenticated;
revoke insert on public.products from authenticated;
grant select on public.inventory_purchases to authenticated;
grant select on public.automatic_day_end_snapshots to authenticated;
grant select on public.sales to authenticated;
grant select on public.daily_closings to authenticated;
grant select, insert, update on public.day_end_summaries to authenticated;
grant select, insert on public.day_end_summary_lines to authenticated;
grant select, update on public.shop_settings to authenticated;
grant select on public.audit_logs to authenticated;

grant execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) to authenticated;
grant execute on function public.submit_daily_closing(date,numeric,numeric,uuid) to authenticated;
grant execute on function public.void_sale(uuid,text) to authenticated;
grant execute on function public.submit_day_end_summary(uuid) to authenticated;
grant execute on function public.confirm_day_end_summary(uuid) to authenticated;
grant execute on function public.approve_closing(uuid) to authenticated;
grant execute on function public.lock_closing(uuid) to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.products;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.sales;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.daily_closings;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.day_end_summaries;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.profiles;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.shop_settings;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.inventory_purchases;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.day_end_summary_lines;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.audit_logs;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ============================================================
-- FINAL SHOP MANAGEMENT CUSTOMER SETUP
-- ============================================================
-- Shop ID is generated by this database.
-- Every customer Supabase project gets its own unique Shop ID.
-- The ID is created automatically when the first owner account is created.
-- ============================================================

alter table public.shop_settings
  add column if not exists shop_id text;

alter table public.profiles
  add column if not exists shop_id text;

-- Database-only Shop ID generator. No pgcrypto/random-bytes dependency.
create or replace function public.generate_shop_id()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id text;
begin
  loop
    v_id := 'SHOP-' || upper(substr(md5(
      clock_timestamp()::text || ':' ||
      random()::text || ':' ||
      txid_current()::text || ':' ||
      coalesce((select max(id)::text from public.audit_logs), '0')
    ), 1, 10));

    exit when not exists (
      select 1 from public.shop_settings
      where upper(trim(coalesce(shop_id,''))) = v_id
    );
  end loop;
  return v_id;
end;
$$;

revoke all on function public.generate_shop_id() from public, anon, authenticated;

-- Keep existing valid IDs. Generate one only when this project has none.
update public.shop_settings
set shop_id = public.generate_shop_id(),
    updated_at = now()
where id = 1
  and (shop_id is null or btrim(shop_id) = '');

alter table public.shop_settings
  alter column shop_id set default public.generate_shop_id();

alter table public.shop_settings
  alter column shop_id set not null;

create unique index if not exists shop_settings_shop_id_uidx
  on public.shop_settings(shop_id);

-- The app can call this after connecting the project. It now returns the
-- database-generated Shop ID instead of requiring the caller to create one.
create or replace function public.initialize_shop(p_shop_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_requested text := upper(trim(coalesce(p_shop_id, '')));
begin
  select s.shop_id
    into v_shop_id
  from public.shop_settings s
  where s.id = 1
  for update;

  if v_shop_id is null or btrim(v_shop_id) = '' then
    v_shop_id := public.generate_shop_id();
    update public.shop_settings
    set shop_id = v_shop_id,
        updated_at = now()
    where id = 1;
  end if;

  -- Backward compatibility: if the app still sends the old license-side ID,
  -- do not overwrite the database-generated Shop ID.
  update public.profiles
  set shop_id = v_shop_id,
      updated_at = now()
  where shop_id is null;

  return jsonb_build_object(
    'ok', true,
    'shop_id', v_shop_id,
    'requested_shop_id', nullif(v_requested, '')
  );
end;
$$;

revoke all on function public.initialize_shop(text) from public;
grant execute on function public.initialize_shop(text) to anon, authenticated;

-- New accounts:
-- first account in this project = owner
-- later accounts = workers
-- accounts are active immediately for the personal/direct-login app flow
-- no owner approval is required
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_has_any_profile boolean;
  v_role public.user_role;
begin
  -- Generate the Shop ID at first account registration if the project
  -- does not already have one.
  select s.shop_id
    into v_shop_id
  from public.shop_settings s
  where s.id = 1
  for update;

  if v_shop_id is null or btrim(v_shop_id) = '' then
    v_shop_id := public.generate_shop_id();
    update public.shop_settings
    set shop_id = v_shop_id,
        updated_at = now()
    where id = 1;
  end if;

  select exists(select 1 from public.profiles)
    into v_has_any_profile;

  v_role := case
    when v_has_any_profile then 'worker'::public.user_role
    else 'owner'::public.user_role
  end;

  insert into public.profiles(
    id, full_name, email, role, is_active, shop_id
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.email, ''),
    v_role,
    true,
    v_shop_id
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case
          when public.profiles.full_name = '' then excluded.full_name
          else public.profiles.full_name
        end,
        shop_id = excluded.shop_id;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Repair old installations where no owner exists.
do $$
begin
  if not exists (
    select 1
    from public.profiles
    where role = 'owner'::public.user_role
  ) then
    update public.profiles
    set role = 'owner'::public.user_role
    where id = (
      select id
      from public.profiles
      order by created_at asc
      limit 1
    );
  end if;
end;
$$;

create or replace function public.activate_user_after_email_verification()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_confirmed timestamptz;
  v_role public.user_role;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'Authentication required.');
  end if;

  select u.email_confirmed_at
    into v_confirmed
  from auth.users u
  where u.id = v_uid;

  if v_confirmed is null then
    return jsonb_build_object('ok', false, 'error', 'Email is not verified yet.');
  end if;

  select p.role
    into v_role
  from public.profiles p
  where p.id = v_uid;

  if v_role is null then
    return jsonb_build_object('ok', false, 'error', 'Account profile not found.');
  end if;

  if v_role <> 'owner'::public.user_role then
    return jsonb_build_object(
      'ok', false,
      'pending_approval', true,
      'role', v_role::text,
      'is_active', false
    );
  end if;

  update public.profiles
  set is_active = true,
      updated_at = now()
  where id = v_uid;

  return jsonb_build_object(
    'ok', true,
    'role', 'owner',
    'is_active', true
  );
end;
$$;

revoke execute on function public.activate_user_after_email_verification() from public, anon;
grant execute on function public.activate_user_after_email_verification() to authenticated;

create or replace function public.handle_user_email_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email_confirmed_at is not null
     and old.email_confirmed_at is null then
    update public.profiles p
    set is_active = true,
        updated_at = now()
    where p.id = new.id
      and p.role = 'owner'::public.user_role;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_email_verified on auth.users;
create trigger on_auth_user_email_verified
after update of email_confirmed_at on auth.users
for each row
execute function public.handle_user_email_verified();

revoke execute on function public.handle_user_email_verified() from public, anon, authenticated;

-- Database verification used by the app.
create or replace function public.verify_shop_management(p_expected_shop_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  missing text[] := '{}';
  current_shop_id text;
  profiles_rls boolean;
  products_rls boolean;
  sales_rls boolean;
  settings_rls boolean;
  expected text := upper(trim(coalesce(p_expected_shop_id, '')));
begin
  if to_regclass('public.profiles') is null then
    missing := array_append(missing, 'profiles table');
  end if;

  if to_regclass('public.products') is null then
    missing := array_append(missing, 'products table');
  end if;

  if to_regclass('public.sales') is null then
    missing := array_append(missing, 'sales table');
  end if;

  if to_regclass('public.shop_settings') is null then
    missing := array_append(missing, 'shop_settings table');
  end if;

  if to_regclass('public.inventory_purchases') is null then
    missing := array_append(missing, 'inventory_purchases table');
  end if;

  if to_regclass('public.daily_closings') is null then
    missing := array_append(missing, 'daily_closings table');
  end if;

  if to_regclass('public.day_end_summaries') is null then
    missing := array_append(missing, 'day_end_summaries table');
  end if;

  if to_regclass('public.profiles') is not null
     and not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'profiles'
         and column_name = 'shop_id'
     ) then
    missing := array_append(missing, 'profiles.shop_id');
  end if;

  if to_regclass('public.shop_settings') is not null then
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'shop_settings'
        and column_name = 'shop_id'
    ) then
      missing := array_append(missing, 'shop_settings.shop_id');
    else
      select s.shop_id
        into current_shop_id
      from public.shop_settings s
      where s.id = 1;

      -- Shop ID is generated by this customer database, not supplied by the license service.
      -- The expected value is therefore informational only and must not block verification.
    end if;
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname = 'record_sale'
  ) then
    missing := array_append(missing, 'record_sale function');
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname = 'add_inventory_purchase'
  ) then
    missing := array_append(missing, 'add_inventory_purchase function');
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname = 'submit_daily_closing'
  ) then
    missing := array_append(missing, 'submit_daily_closing function');
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname = 'clear_all_shop_data'
  ) then
    missing := array_append(missing, 'clear_all_shop_data function');
  end if;

  if not exists (
    select 1 from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname = 'handle_new_user'
  ) then
    missing := array_append(missing, 'handle_new_user function');
  end if;

  select c.relrowsecurity
    into profiles_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'profiles';

  select c.relrowsecurity
    into products_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'products';

  select c.relrowsecurity
    into sales_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'sales';

  select c.relrowsecurity
    into settings_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shop_settings';

  if not coalesce(profiles_rls, false) then
    missing := array_append(missing, 'profiles RLS');
  end if;
  if not coalesce(products_rls, false) then
    missing := array_append(missing, 'products RLS');
  end if;
  if not coalesce(sales_rls, false) then
    missing := array_append(missing, 'sales RLS');
  end if;
  if not coalesce(settings_rls, false) then
    missing := array_append(missing, 'shop_settings RLS');
  end if;

  return jsonb_build_object(
    'ok', cardinality(missing) = 0,
    'shop_id', current_shop_id,
    'missing', to_jsonb(missing),
    'checks', jsonb_build_object(
      'profiles', to_regclass('public.profiles') is not null,
      'products', to_regclass('public.products') is not null,
      'sales', to_regclass('public.sales') is not null,
      'shop_settings', to_regclass('public.shop_settings') is not null,
      'inventory_purchases', to_regclass('public.inventory_purchases') is not null,
      'daily_closings', to_regclass('public.daily_closings') is not null,
      'day_end_summaries', to_regclass('public.day_end_summaries') is not null,
      'shop_id', current_shop_id is not null and btrim(current_shop_id) <> '',
      'record_sale', exists (
        select 1 from pg_proc
        where pronamespace = 'public'::regnamespace
          and proname = 'record_sale'
      ),
      'record_purchase', exists (
        select 1 from pg_proc
        where pronamespace = 'public'::regnamespace
          and proname = 'add_inventory_purchase'
      ),
      'rls',
        coalesce(profiles_rls, false)
        and coalesce(products_rls, false)
        and coalesce(sales_rls, false)
        and coalesce(settings_rls, false)
    )
  );
end;
$$;

revoke all on function public.verify_shop_management(text) from public;
grant execute on function public.verify_shop_management(text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- ============================================================
-- REALTIME
-- ============================================================
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception
  when duplicate_object then null;
  when undefined_object then null;
end;
$$;

-- ============================================================
-- END OF FINAL SHOP MANAGEMENT SQL
-- ============================================================

-- ============================================================
-- CART + CREDIT WORKFLOW MIGRATION
-- ============================================================
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

  -- Use TRUNCATE instead of DELETE so pg_safeupdate / WHERE enforcement
  -- cannot reject the clear operation. All transaction tables and their
  -- dependent ledger/summary tables are explicitly included.
  truncate table
    public.debtor_ledger,
    public.credit_ledger,
    public.sale_transactions,
    public.sales,
    public.inventory_purchases,
    public.daily_closings,
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.automatic_day_end_snapshots,
    public.daily_financial_summaries,
    public.lifetime_financial_summaries,
    public.creditor_daily_financial_aggregates,
    public.returns,
    public.audit_logs
    restart identity;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base = 0,
      updated_at = now()
  where id is not null;

  perform set_config('shop.allow_stock_change','off',true);

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    details
  )
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
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


-- ============================================================
-- SHOP MANAGEMENT STORAGE-EFFICIENT REDESIGN
-- Run after the existing FINAL_ALL_IN_ONE.sql on the test Supabase project.
-- This migration implements the retention rules from the Storage-Efficient App & Database Blueprint.

create extension if not exists pgcrypto;

-- ============================================================
-- 1. Purchase payment + pre-stock fields
-- ============================================================
alter table public.inventory_purchases
  add column if not exists payment_mode text not null default 'pre_stock',
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0,
  add column if not exists credit_amount numeric(14,2) not null default 0,
  add column if not exists credit_paid numeric(14,2) not null default 0,
  add column if not exists pre_stock boolean not null default false,
  add column if not exists supplier_name text not null default '';

update public.inventory_purchases
set pre_stock = true,
    payment_mode = 'pre_stock',
    cash_amount = 0,
    upi_amount = 0,
    credit_amount = 0,
    credit_paid = 0
where payment_mode is null or payment_mode = '';

-- Repair legacy rows created before purchase payment fields existed.
update public.inventory_purchases
set payment_mode = 'cash',
    pre_stock = false,
    cash_amount = round(total_cost,2),
    upi_amount = 0,
    credit_amount = 0,
    credit_paid = 0
where coalesce(pre_stock,false)=false
  and payment_mode='pre_stock'
  and coalesce(cash_amount,0)=0
  and coalesce(upi_amount,0)=0
  and coalesce(credit_amount,0)=0
  and total_cost > 0;

-- Normalize any remaining inconsistent non-pre-stock rows.
update public.inventory_purchases
set payment_mode = case
      when abs(coalesce(cash_amount,0)+coalesce(upi_amount,0)-total_cost) <= 0.01
           and coalesce(cash_amount,0) > 0 and coalesce(upi_amount,0) > 0 then 'split'
      when abs(coalesce(upi_amount,0)-total_cost) <= 0.01 then 'upi'
      when abs(coalesce(cash_amount,0)-total_cost) <= 0.01 then 'cash'
      when abs(coalesce(credit_amount,0)-total_cost) <= 0.01 then 'credit'
      else 'cash'
    end,
    pre_stock = false,
    cash_amount = case
      when abs(coalesce(cash_amount,0)+coalesce(upi_amount,0)-total_cost) <= 0.01
           and coalesce(cash_amount,0) > 0 and coalesce(upi_amount,0) > 0 then round(coalesce(cash_amount,0),2)
      when abs(coalesce(upi_amount,0)-total_cost) <= 0.01 then 0
      when abs(coalesce(credit_amount,0)-total_cost) <= 0.01 then 0
      else round(total_cost,2)
    end,
    upi_amount = case
      when abs(coalesce(cash_amount,0)+coalesce(upi_amount,0)-total_cost) <= 0.01
           and coalesce(cash_amount,0) > 0 and coalesce(upi_amount,0) > 0 then round(coalesce(upi_amount,0),2)
      when abs(coalesce(upi_amount,0)-total_cost) <= 0.01 then round(total_cost,2)
      else 0
    end,
    credit_amount = case
      when abs(coalesce(credit_amount,0)-total_cost) <= 0.01 then round(total_cost,2)
      else 0
    end,
    credit_paid = 0
where coalesce(pre_stock,false)=false
  and not (
    (payment_mode='cash' and abs(coalesce(cash_amount,0)-total_cost)<=0.01 and coalesce(upi_amount,0)=0 and coalesce(credit_amount,0)=0)
    or (payment_mode='upi' and abs(coalesce(upi_amount,0)-total_cost)<=0.01 and coalesce(cash_amount,0)=0 and coalesce(credit_amount,0)=0)
    or (payment_mode='split' and abs(coalesce(cash_amount,0)+coalesce(upi_amount,0)-total_cost)<=0.01 and coalesce(credit_amount,0)=0)
    or (payment_mode='credit' and abs(coalesce(credit_amount,0)-total_cost)<=0.01 and coalesce(cash_amount,0)=0 and coalesce(upi_amount,0)=0)
  );

alter table public.inventory_purchases
  drop constraint if exists inventory_purchases_payment_check;
alter table public.inventory_purchases
  add constraint inventory_purchases_payment_check
  check (
    payment_mode in ('cash','upi','split','credit','pre_stock')
    and cash_amount >= 0
    and upi_amount >= 0
    and credit_amount >= 0
    and credit_paid >= 0
    and credit_paid <= credit_amount
    and (
      pre_stock = true
      or (
        payment_mode='cash' and abs(cash_amount-total_cost) <= 0.01 and upi_amount=0 and credit_amount=0
        or payment_mode='upi' and abs(upi_amount-total_cost) <= 0.01 and cash_amount=0 and credit_amount=0
        or payment_mode='split' and abs((cash_amount+upi_amount)-total_cost) <= 0.01 and credit_amount=0
        or payment_mode='credit' and abs(credit_amount-total_cost) <= 0.01 and cash_amount=0 and upi_amount=0
      )
    )
  );

create index if not exists purchases_payment_mode_idx on public.inventory_purchases(payment_mode);
create index if not exists purchases_prestock_idx on public.inventory_purchases(pre_stock);

-- ============================================================
-- 2. Permanent daily financial aggregates
-- ============================================================
create table if not exists public.daily_financial_summaries (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  business_date date not null,
  total_transactions integer not null default 0,
  total_revenue numeric(14,2) not null default 0,
  cash_sales numeric(14,2) not null default 0,
  upi_sales numeric(14,2) not null default 0,
  credit_sales numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  cash_profit numeric(14,2) not null default 0,
  upi_profit numeric(14,2) not null default 0,
  credit_profit numeric(14,2) not null default 0,
  creditor_amount numeric(14,2) not null default 0,
  purchase_cash numeric(14,2) not null default 0,
  purchase_upi numeric(14,2) not null default 0,
  purchase_credit numeric(14,2) not null default 0,
  total_purchases numeric(14,2) not null default 0,
  updated_at timestamptz not null default now(),
  unique(shop_id,business_date)
);

create index if not exists daily_financial_summaries_shop_date_idx
  on public.daily_financial_summaries(shop_id,business_date desc);

create table if not exists public.lifetime_financial_summaries (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null unique,
  lifetime_sales numeric(16,2) not null default 0,
  lifetime_purchases numeric(16,2) not null default 0,
  lifetime_profit numeric(16,2) not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.creditor_daily_financial_aggregates (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  creditor_id uuid not null references public.creditors(id) on delete cascade,
  business_date date not null,
  credit_sales numeric(14,2) not null default 0,
  payment_cash numeric(14,2) not null default 0,
  payment_upi numeric(14,2) not null default 0,
  payment_total numeric(14,2) not null default 0,
  updated_at timestamptz not null default now(),
  unique(shop_id,creditor_id,business_date)
);

create index if not exists creditor_daily_aggregate_shop_date_idx
  on public.creditor_daily_financial_aggregates(shop_id,business_date desc);

alter table public.daily_financial_summaries add column if not exists pre_stock_purchases numeric(14,2) not null default 0;

-- ============================================================
-- 3. Refresh one day's permanent aggregate
-- ============================================================
create or replace function public.refresh_daily_financial_summary(
  p_shop_id text,
  p_business_date date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata')
    into v_tz
  from public.shop_settings
  where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,updated_at
  )
  select
    p_shop_id,
    p_business_date,
    coalesce(s.tx_count,0),
    coalesce(s.revenue,0),
    coalesce(s.cash,0),
    coalesce(s.upi,0),
    coalesce(s.credit,0),
    coalesce(s.profit,0),
    coalesce(s.cash_profit,0),
    coalesce(s.upi_profit,0),
    coalesce(s.credit_profit,0),
    coalesce(s.credit,0),
    coalesce(p.cash_purchase,0),
    coalesce(p.upi_purchase,0),
    coalesce(p.credit_purchase,0),
    coalesce(p.total_purchase,0),
    coalesce(p.pre_stock_purchase,0),
    now()
  from
    (select 1) seed
    left join lateral (
      select
        count(distinct coalesce(s.transaction_id,s.id))::integer as tx_count,
        coalesce(sum(s.total_sale),0)::numeric as revenue,
        coalesce(sum(s.cash_amount),0)::numeric as cash,
        coalesce(sum(s.upi_amount),0)::numeric as upi,
        coalesce(sum(case when s.payment_mode in ('credit','credit_split')
          then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric as credit,
        coalesce(sum(s.gross_profit),0)::numeric as profit,
        coalesce(sum(case when s.payment_mode='cash' then s.gross_profit
          when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*(s.cash_amount/s.total_sale)
          else 0 end),0)::numeric as cash_profit,
        coalesce(sum(case when s.payment_mode='upi' then s.gross_profit
          when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*(s.upi_amount/s.total_sale)
          else 0 end),0)::numeric as upi_profit,
        coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0
          then s.gross_profit*(greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale)
          else 0 end),0)::numeric as credit_profit
      from public.sales s
      join public.profiles w on w.id=s.worker_id
      where w.shop_id=p_shop_id
        and not s.voided
        and (s.sold_at at time zone v_tz)::date=p_business_date
    ) s on true
    left join lateral (
      select
        coalesce(sum(case when i.payment_mode='cash' then i.total_cost else 0 end),0)::numeric as cash_purchase,
        coalesce(sum(case when i.payment_mode='upi' then i.total_cost else 0 end),0)::numeric as upi_purchase,
        coalesce(sum(case when i.payment_mode='credit' then i.total_cost else 0 end),0)::numeric as credit_purchase,
        coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric as total_purchase,
        coalesce(sum(case when coalesce(i.pre_stock,false)=true then i.total_cost else 0 end),0)::numeric as pre_stock_purchase
      from public.inventory_purchases i
      join public.profiles w on w.id=i.purchased_by
      where w.shop_id=p_shop_id
        and (i.purchased_at at time zone v_tz)::date=p_business_date
    ) p on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,
    total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,
    upi_sales=excluded.upi_sales,
    credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,
    cash_profit=excluded.cash_profit,
    upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,
    creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,
    purchase_upi=excluded.purchase_upi,
    purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,
    pre_stock_purchases=excluded.pre_stock_purchases,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.lifetime_financial_summaries(
    shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at
  )
  select
    p_shop_id,
    coalesce(sum(total_revenue),0),
    coalesce(sum(total_purchases+pre_stock_purchases),0),
    coalesce(sum(total_profit),0),
    now()
  from public.daily_financial_summaries
  where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;

-- ============================================================
-- 4. Permanent creditor/day payment aggregates
-- ============================================================
create or replace function public.refresh_creditor_daily_aggregate(
  p_shop_id text,
  p_creditor_id uuid,
  p_business_date date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.creditor_daily_financial_aggregates(
    shop_id,creditor_id,business_date,credit_sales,payment_cash,payment_upi,payment_total,updated_at
  )
  select
    p_shop_id,p_creditor_id,p_business_date,
    coalesce(sum(case when type='credit_sale' then amount else 0 end),0),
    coalesce(sum(case when type='payment_received' then cash_amount else 0 end),0),
    coalesce(sum(case when type='payment_received' then upi_amount else 0 end),0),
    coalesce(sum(case when type='payment_received' then amount else 0 end),0),
    now()
  from public.credit_ledger
  where shop_id=p_shop_id
    and creditor_id=p_creditor_id
    and (created_at at time zone v_tz)::date=p_business_date
  on conflict(shop_id,creditor_id,business_date) do update set
    credit_sales=excluded.credit_sales,
    payment_cash=excluded.payment_cash,
    payment_upi=excluded.payment_upi,
    payment_total=excluded.payment_total,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_creditor_daily_aggregate(text,uuid,date) from public,anon,authenticated;

-- ============================================================
-- 5. Backfill permanent aggregates before any cleanup
-- ============================================================
do $$
declare
  r record;
begin
  for r in
    select distinct w.shop_id, (s.sold_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date business_date
    from public.sales s
    join public.profiles w on w.id=s.worker_id
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct w.shop_id, (i.purchased_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date business_date
    from public.inventory_purchases i
    join public.profiles w on w.id=i.purchased_by
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;

  for r in
    select distinct cl.shop_id,cl.creditor_id,(cl.created_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date business_date
    from public.credit_ledger cl
    cross join public.shop_settings st
  loop
    perform public.refresh_creditor_daily_aggregate(r.shop_id,r.creditor_id,r.business_date);
  end loop;
end;
$$;

-- ============================================================
-- 6. Triggers keep permanent aggregates current
-- ============================================================
create or replace function public.sales_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop text;
  v_tz text;
begin
  select shop_id into v_shop from public.profiles where id=coalesce(new.worker_id,old.worker_id);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  if old is not null then
    perform public.refresh_daily_financial_summary(v_shop,(old.sold_at at time zone v_tz)::date);
  end if;
  if new is not null then
    perform public.refresh_daily_financial_summary(v_shop,(new.sold_at at time zone v_tz)::date);
  end if;
  perform public.refresh_lifetime_financial_summary(v_shop);
  return coalesce(new,old);
end;
$$;

drop trigger if exists sales_financial_aggregate_trigger on public.sales;
create trigger sales_financial_aggregate_trigger
after insert or update or delete on public.sales
for each row execute function public.sales_financial_aggregate_trigger();

create or replace function public.purchase_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop text;
  v_tz text;
begin
  select shop_id into v_shop from public.profiles where id=coalesce(new.purchased_by,old.purchased_by);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  if old is not null then
    perform public.refresh_daily_financial_summary(v_shop,(old.purchased_at at time zone v_tz)::date);
  end if;
  if new is not null then
    perform public.refresh_daily_financial_summary(v_shop,(new.purchased_at at time zone v_tz)::date);
  end if;
  perform public.refresh_lifetime_financial_summary(v_shop);
  return coalesce(new,old);
end;
$$;

drop trigger if exists purchase_financial_aggregate_trigger on public.inventory_purchases;
create trigger purchase_financial_aggregate_trigger
after insert or update or delete on public.inventory_purchases
for each row execute function public.purchase_financial_aggregate_trigger();

create or replace function public.creditor_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop text;
  v_tz text;
begin
  v_shop:=coalesce(new.shop_id,old.shop_id);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  if old is not null then
    perform public.refresh_creditor_daily_aggregate(v_shop,old.creditor_id,(old.created_at at time zone v_tz)::date);
  end if;
  if new is not null then
    perform public.refresh_creditor_daily_aggregate(v_shop,new.creditor_id,(new.created_at at time zone v_tz)::date);
  end if;
  return coalesce(new,old);
end;
$$;

drop trigger if exists creditor_aggregate_trigger on public.credit_ledger;
create trigger creditor_aggregate_trigger
after insert or update or delete on public.credit_ledger
for each row execute function public.creditor_aggregate_trigger();

-- ============================================================
-- 7. Pay purchase credit
-- ============================================================
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
  r public.inventory_purchases;
  v_shop text;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount <= 0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  select i.* into r
  from public.inventory_purchases i
  join public.profiles p on p.id=i.purchased_by
  where i.id=p_purchase_id
    and p.shop_id=(select shop_id from public.profiles where id=(select auth.uid()))
  for update;

  if not found then raise exception 'Purchase not found'; end if;
  if r.pre_stock then raise exception 'Pre-stock records cannot have purchase credit'; end if;
  if p_amount > (r.credit_amount-r.credit_paid)+0.01 then raise exception 'Payment exceeds purchase credit balance'; end if;

  update public.inventory_purchases
  set credit_paid=credit_paid+p_amount
  where id=p_purchase_id
  returning * into r;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values((select auth.uid()),'purchase_credit_paid','inventory_purchase',p_purchase_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode));

  return r;
end;
$$;

revoke all on function public.pay_purchase_credit(uuid,numeric,text) from public,anon;
grant execute on function public.pay_purchase_credit(uuid,numeric,text) to authenticated;

-- ============================================================
-- 8. Database-level retention cleanup
-- ============================================================
create or replace function public.run_storage_retention_cleanup()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sales_deleted bigint:=0;
  v_purchase_deleted bigint:=0;
  v_audit_deleted bigint:=0;
  v_credit_deleted bigint:=0;
  v_row_count bigint:=0;
  r record;
begin
  -- Always refresh the permanent aggregate before deleting detail.
  for r in
    select distinct w.shop_id,(s.sold_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date business_date
    from public.sales s
    join public.profiles w on w.id=s.worker_id
    cross join public.shop_settings st
    where s.sold_at < now()-interval '90 days'
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct w.shop_id,(i.purchased_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date business_date
    from public.inventory_purchases i
    join public.profiles w on w.id=i.purchased_by
    cross join public.shop_settings st
    where i.purchased_at < now()-interval '1 year'
      and coalesce(i.pre_stock,false)=false
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  delete from public.sales where sold_at < now()-interval '90 days';
  get diagnostics v_sales_deleted=row_count;

  delete from public.sale_transactions
  where created_at < now()-interval '90 days'
    and not exists(select 1 from public.sales s where s.transaction_id=sale_transactions.id);
  
  delete from public.inventory_purchases
  where purchased_at < now()-interval '1 year'
    and coalesce(pre_stock,false)=false
    and (credit_amount-credit_paid) <= 0.01;
  get diagnostics v_purchase_deleted=row_count;

  delete from public.audit_logs where created_at < now()-interval '30 days';
  get diagnostics v_audit_deleted=row_count;

  -- Customer-credit detail is retained forever while balance is outstanding.
  -- Once balance reaches zero, detail is retained for 7 more days, while the
  -- creditor_daily_financial_aggregates table remains permanent.
  for r in
    select c.id,c.shop_id
    from public.creditors c
    where not exists (
      select 1 from public.credit_ledger l
      where l.creditor_id=c.id
        and l.shop_id=c.shop_id
      group by l.creditor_id
      having coalesce(sum(case
        when l.type='credit_sale' then l.amount
        when l.type='payment_received' then -l.amount
        else l.amount end),0) > 0.01
    )
  loop
    delete from public.credit_ledger
    where creditor_id=r.id
      and shop_id=r.shop_id
      and created_at < now()-interval '7 days';
    get diagnostics v_row_count=row_count;
    v_credit_deleted:=v_credit_deleted+v_row_count;
  end loop;

  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;

  return jsonb_build_object(
    'sales_deleted',v_sales_deleted,
    'purchases_deleted',v_purchase_deleted,
    'audit_deleted',v_audit_deleted,
    'paid_credit_detail_deleted',v_credit_deleted,
    'ran_at',now()
  );
end;
$$;

revoke all on function public.run_storage_retention_cleanup() from public,anon,authenticated;

-- ============================================================
-- 9. Remove obsolete day-end workflow tables
-- ============================================================
drop table if exists public.day_end_summary_lines cascade;
drop table if exists public.day_end_summaries cascade;
drop table if exists public.daily_closings cascade;
drop table if exists public.automatic_day_end_snapshots cascade;

-- ============================================================
-- 10. New verification + clear-all functions after obsolete workflow removal
-- ============================================================
create or replace function public.verify_shop_management(p_expected_shop_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  missing text[] := '{}';
begin
  if to_regclass('public.profiles') is null then missing:=array_append(missing,'profiles'); end if;
  if to_regclass('public.products') is null then missing:=array_append(missing,'products'); end if;
  if to_regclass('public.sales') is null then missing:=array_append(missing,'sales'); end if;
  if to_regclass('public.inventory_purchases') is null then missing:=array_append(missing,'inventory_purchases'); end if;
  if to_regclass('public.creditors') is null then missing:=array_append(missing,'creditors'); end if;
  if to_regclass('public.credit_ledger') is null then missing:=array_append(missing,'credit_ledger'); end if;
  if to_regclass('public.daily_financial_summaries') is null then missing:=array_append(missing,'daily_financial_summaries'); end if;
  if to_regclass('public.lifetime_financial_summaries') is null then missing:=array_append(missing,'lifetime_financial_summaries'); end if;
  if to_regclass('public.audit_logs') is null then missing:=array_append(missing,'audit_logs'); end if;
  return jsonb_build_object('ok',cardinality(missing)=0,'missing',to_jsonb(missing));
end;
$$;

revoke all on function public.verify_shop_management(text) from public;
-- Anonymous access is intentionally limited to the setup/installation check.
-- The function only reports whether the required Shop Management schema exists;
-- all actual application data remains protected by authentication and RLS.
grant execute on function public.verify_shop_management(text) to anon, authenticated;

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

  -- Use TRUNCATE instead of DELETE so pg_safeupdate / WHERE enforcement
  -- cannot reject the clear operation. All transaction tables and their
  -- dependent ledger/summary tables are explicitly included.
  truncate table
    public.debtor_ledger,
    public.credit_ledger,
    public.sale_transactions,
    public.sales,
    public.inventory_purchases,
    public.daily_closings,
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.automatic_day_end_snapshots,
    public.daily_financial_summaries,
    public.lifetime_financial_summaries,
    public.creditor_daily_financial_aggregates,
    public.returns,
    public.audit_logs
    restart identity;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base = 0,
      updated_at = now()
  where id is not null;

  perform set_config('shop.allow_stock_change','off',true);

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    details
  )
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object('cleared_at',now())
  );
end;
$clear_all$;

revoke all on function public.clear_all_shop_data() from public,anon;
grant execute on function public.clear_all_shop_data() to authenticated;

select pg_notify('pgrst','reload schema');

-- ============================================================
-- PATCH: atomic purchase + returns + business-day consistency
-- ============================================================
alter table public.inventory_purchases
  add column if not exists payment_mode text not null default 'cash',
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0,
  add column if not exists credit_amount numeric(14,2) not null default 0,
  add column if not exists credit_paid numeric(14,2) not null default 0,
  add column if not exists pre_stock boolean not null default false,
  add column if not exists supplier_name text,
  add column if not exists debtor_id uuid references public.debtors(id) on delete set null;

create table if not exists public.returns (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  return_type text not null check (return_type in ('sale','purchase')),
  product_id uuid references public.products(id) on delete set null,
  product_name_snapshot text not null default 'Deleted product',
  quantity_base numeric(14,3) not null check (quantity_base > 0),
  quantity_display numeric(14,3) not null check (quantity_display > 0),
  return_unit text not null,
  return_price_per_base_unit numeric(12,2) not null check (return_price_per_base_unit >= 0),
  total_amount numeric(14,2) not null check (total_amount >= 0),
  cost_amount numeric(14,2) not null default 0 check (cost_amount >= 0),
  profit_impact numeric(14,2) not null default 0,
  payment_mode text not null check (payment_mode in ('cash','upi','credit_adjustment')),
  cash_amount numeric(14,2) not null default 0 check (cash_amount >= 0),
  upi_amount numeric(14,2) not null default 0 check (upi_amount >= 0),
  credit_amount numeric(14,2) not null default 0 check (credit_amount >= 0),
  source_id uuid,
  creditor_id uuid references public.creditors(id) on delete set null,
  debtor_id uuid references public.debtors(id) on delete set null,
  reason text not null,
  returned_by uuid not null references public.profiles(id),
  returned_at timestamptz not null default now()
);
create index if not exists returns_shop_date_idx on public.returns(shop_id,returned_at desc);
create index if not exists returns_product_idx on public.returns(product_id);
create index if not exists returns_type_idx on public.returns(return_type);

alter table public.daily_financial_summaries
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0;

create or replace function public.business_date(p_ts timestamptz default now())
returns date
language plpgsql stable security definer set search_path=''
as $$
declare
  tz text;
  reset_text text;
  local_ts timestamp;
  reset_minutes integer;
begin
  select coalesce(timezone,'Asia/Kolkata'),coalesce(dashboard_reset_time,'00:00')
    into tz,reset_text from public.shop_settings where id=1;
  local_ts := p_ts at time zone tz;
  reset_minutes := split_part(reset_text,':',1)::integer*60 + split_part(reset_text,':',2)::integer;
  if extract(hour from local_ts)*60 + extract(minute from local_ts) < reset_minutes then
    return (local_ts::date - 1);
  end if;
  return local_ts::date;
end;
$$;
revoke all on function public.business_date(timestamptz) from public,anon,authenticated;
grant execute on function public.business_date(timestamptz) to authenticated;

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
language plpgsql security definer set search_path=''
as $$
declare
  p public.products;
  total numeric;
  cash numeric := coalesce(p_cash_amount,0);
  upi numeric := coalesce(p_upi_amount,0);
  credit numeric := coalesce(p_credit_amount,0);
  v_id uuid;
  v_shop text;
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
    cash:=total;upi:=0;credit:=0;
  elsif p_payment_mode='upi' then
    cash:=0;upi:=total;credit:=0;
  elsif p_payment_mode='credit' then
    cash:=0;upi:=0;credit:=total;
  elsif p_payment_mode='split' then
    if cash<0 or upi<0 or abs(cash+upi-total)>0.01 then
      raise exception 'Cash + UPI must equal purchase total';
    end if;
    credit:=0;
  end if;

  if not is_pre_stock then
    if cash<0 or upi<0 or credit<0 or abs(cash+upi+credit-total)>0.01 then
      raise exception 'Purchase payment amounts must equal purchase total';
    end if;
  end if;

  if credit>0 then
    if p_debtor_id is null then raise exception 'Credit purchase requires a debtor'; end if;
    if not exists(
      select 1 from public.debtors
      where id=p_debtor_id
        and shop_id=(select shop_id from public.profiles where id=auth.uid())
        and is_active=true
    ) then
      raise exception 'Debtor not found';
    end if;
  elsif p_debtor_id is not null then
    raise exception 'Debtor is only valid for credit purchases';
  end if;

  v_shop:=(select shop_id from public.profiles where id=auth.uid());

  insert into public.inventory_purchases(
    product_id,product_name_snapshot,quantity_base,quantity_display,purchase_unit,
    purchase_price_per_base_unit,total_cost,purchased_by,payment_mode,cash_amount,upi_amount,
    credit_amount,credit_paid,pre_stock,supplier_name,debtor_id
  ) values (
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

  if credit>0 then
    insert into public.debtor_ledger(shop_id,debtor_id,purchase_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
    values(v_shop,p_debtor_id,v_id,'credit_purchase',credit,'credit',0,0,auth.uid(),'Credit purchase');
  end if;

  perform public.write_audit(
    'purchase_added','inventory_purchase',v_id,
    jsonb_build_object(
      'total',total,
      'payment_mode',p_payment_mode,
      'cash',cash,
      'upi',upi,
      'credit',credit,
      'pre_stock',is_pre_stock,
      'purchase_price',p_purchase_price,
      'selling_price',coalesce(p_selling_price,p.selling_price_per_base_unit)
    )
  );
  return v_id;
end;
$$;

revoke all on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text,numeric) from public,anon;
grant execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric,text,numeric,numeric,numeric,uuid,boolean,text,numeric) to authenticated;

drop function if exists public.add_inventory_purchase(uuid,numeric,numeric,text,numeric);

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
  p_supplier_name text default null
) returns uuid
language sql security definer set search_path=''
as $compat$
  select public.add_inventory_purchase(
    p_product_id,p_quantity_base,p_quantity_display,p_purchase_unit,p_purchase_price,
    p_payment_mode,p_cash_amount,p_upi_amount,p_credit_amount,p_debtor_id,
    p_pre_stock,p_supplier_name,null
  );
$compat$;


create or replace function public.record_purchase_return(
  p_product_id uuid,p_quantity_base numeric,p_quantity_display numeric,p_return_unit text,
  p_return_price_per_base_unit numeric,p_payment_mode text default 'cash',
  p_source_id uuid default null,p_reason text default '',p_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  p public.products; src public.inventory_purchases; total numeric; v_id uuid; debtor uuid; v_shop text;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_return_price_per_base_unit<0 then raise exception 'Invalid return'; end if;
  if p_payment_mode not in ('cash','upi','credit_adjustment') then raise exception 'Invalid return payment mode'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if p_return_unit<>'piece' or p_quantity_display<>p_quantity_base or mod(p_quantity_base,1)<>0 then raise exception 'Piece return must be whole pieces'; end if;
  else
    if p_return_unit not in ('grams','kg') then raise exception 'Weight return must use grams or kg'; end if;
    if p_return_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg return'; end if;
    if p_return_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram return'; end if;
  end if;
  if p.current_stock_base<p_quantity_base then raise exception 'Insufficient stock for purchase return'; end if;
  if p_source_id is not null then
    select * into src from public.inventory_purchases where id=p_source_id and product_id=p_product_id for share;
    if not found then raise exception 'Original purchase not found'; end if;
    if p_quantity_base > src.quantity_base - coalesce((select sum(r.quantity_base) from public.returns r where r.return_type='purchase' and r.source_id=src.id),0)
      then raise exception 'Purchase return exceeds original purchase quantity'; end if;
    debtor:=src.debtor_id;
  else debtor:=p_account_id; end if;
  if p_payment_mode='credit_adjustment' and debtor is null then raise exception 'Select the supplier/debtor for a credit adjustment'; end if;
  total:=case when p.unit_type='weight' then round((p_quantity_base/1000)*p_return_price_per_base_unit,2) else round(p_quantity_base*p_return_price_per_base_unit,2) end;
  v_shop:=(select shop_id from public.profiles where id=auth.uid());
  insert into public.returns(shop_id,return_type,product_id,product_name_snapshot,quantity_base,quantity_display,return_unit,return_price_per_base_unit,total_amount,cost_amount,profit_impact,payment_mode,cash_amount,upi_amount,credit_amount,source_id,debtor_id,reason,returned_by)
  values(v_shop,'purchase',p_product_id,p.name,p_quantity_base,p_quantity_display,p_return_unit,p_return_price_per_base_unit,total,total,0,p_payment_mode,case when p_payment_mode='cash' then total else 0 end,case when p_payment_mode='upi' then total else 0 end,case when p_payment_mode='credit_adjustment' then total else 0 end,p_source_id,debtor,trim(p_reason),auth.uid()) returning id into v_id;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base-p_quantity_base,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  if p_payment_mode='credit_adjustment' then
    insert into public.debtor_ledger(shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
    values(v_shop,debtor,'payment_made',total,'credit',0,0,auth.uid(),'Purchase return');
  end if;
  perform public.write_audit('purchase_return','return',v_id,jsonb_build_object('total',total,'quantity_base',p_quantity_base,'source_id',p_source_id));
  return v_id;
end;
$$;

create or replace function public.record_sale_return(
  p_product_id uuid,p_quantity_base numeric,p_quantity_display numeric,p_return_unit text,
  p_return_price_per_base_unit numeric,p_payment_mode text default 'cash',
  p_source_id uuid default null,p_reason text default '',p_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  p public.products; src public.sales; total numeric; cost numeric; profit numeric; v_id uuid; creditor uuid; v_shop text;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_return_price_per_base_unit<0 then raise exception 'Invalid return'; end if;
  if p_payment_mode not in ('cash','upi','credit_adjustment') then raise exception 'Invalid return payment mode'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if p_return_unit<>'piece' or p_quantity_display<>p_quantity_base or mod(p_quantity_base,1)<>0 then raise exception 'Piece return must be whole pieces'; end if;
  else
    if p_return_unit not in ('grams','kg') then raise exception 'Weight sale return must use grams or kg'; end if;
    if p_return_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg return'; end if;
    if p_return_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram return'; end if;
  end if;
  if p_source_id is not null then
    select * into src from public.sales where id=p_source_id and product_id=p_product_id and not voided for share;
    if not found then raise exception 'Original sale not found'; end if;
    if p_quantity_base > src.quantity_base - coalesce((select sum(r.quantity_base) from public.returns r where r.return_type='sale' and r.source_id=src.id),0)
      then raise exception 'Sale return exceeds original sold quantity'; end if;
    cost:=case when src.quantity_base>0 then round(src.total_cost/src.quantity_base*p_quantity_base,2) else 0 end;
    select st.creditor_id into creditor from public.sale_transactions st where st.id=src.transaction_id;
  else
    cost:=case when p.unit_type='weight' then round((p_quantity_base/1000)*p.purchase_price_per_base_unit,2) else round(p_quantity_base*p.purchase_price_per_base_unit,2) end;
    creditor:=p_account_id;
  end if;
  if p_payment_mode='credit_adjustment' and creditor is null then raise exception 'Select the customer/creditor for a credit adjustment'; end if;
  total:=case when p.unit_type='weight' then round((p_quantity_base/1000)*p_return_price_per_base_unit,2) else round(p_quantity_base*p_return_price_per_base_unit,2) end;
  profit:=-(total-cost);
  v_shop:=(select shop_id from public.profiles where id=auth.uid());
  insert into public.returns(shop_id,return_type,product_id,product_name_snapshot,quantity_base,quantity_display,return_unit,return_price_per_base_unit,total_amount,cost_amount,profit_impact,payment_mode,cash_amount,upi_amount,credit_amount,source_id,creditor_id,reason,returned_by)
  values(v_shop,'sale',p_product_id,p.name,p_quantity_base,p_quantity_display,p_return_unit,p_return_price_per_base_unit,total,cost,profit,p_payment_mode,case when p_payment_mode='cash' then total else 0 end,case when p_payment_mode='upi' then total else 0 end,case when p_payment_mode='credit_adjustment' then total else 0 end,p_source_id,creditor,trim(p_reason),auth.uid()) returning id into v_id;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base+p_quantity_base,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  if p_payment_mode='credit_adjustment' then
    insert into public.credit_ledger(shop_id,creditor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
    values(v_shop,creditor,'payment_received',total,'credit',0,0,auth.uid(),'Sale return credit adjustment');
  end if;
  perform public.write_audit('sale_return','return',v_id,jsonb_build_object('total',total,'cost',cost,'profit_impact',profit,'source_id',p_source_id));
  return v_id;
end;
$$;
revoke all on function public.record_purchase_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) from public,anon;
revoke all on function public.record_sale_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) from public,anon;
grant execute on function public.record_purchase_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) to authenticated;
grant execute on function public.record_sale_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) to authenticated;

-- Returns are part of the permanent daily financial picture.
create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at)
  select p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    coalesce(s.cash,0)-coalesce(r.sales_cash,0),
    coalesce(s.upi,0)-coalesce(r.sales_upi,0),
    coalesce(s.credit,0)-coalesce(r.sales_credit,0),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),
    coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),
    coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),
    coalesce(s.credit,0)-coalesce(r.sales_credit,0),
    coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),
    coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),
    coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),
    coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),
    coalesce(p.pre_stock_purchase,0),
    coalesce(r.sales_ret,0),coalesce(r.purchase_ret,0),coalesce(r.sales_profit_impact,0),coalesce(d.pay_cash,0),coalesce(d.pay_upi,0),coalesce(d.pay_total,0),now()
  from (select 1) seed
  left join lateral (
    select count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and public.business_date(s.sold_at)=p_business_date
  ) s on true
  left join lateral (
    select coalesce(sum(case when coalesce(i.pre_stock,false)=false and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false)=false and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false)=false then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and public.business_date(i.purchased_at)=p_business_date
  ) p on true
  left join lateral (
    select coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and public.business_date(dl.created_at)=p_business_date
  ) d on true
  left join lateral (
    select coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns where shop_id=p_shop_id and public.business_date(returned_at)=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,cash_sales=excluded.cash_sales,
    upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,total_profit=excluded.total_profit,
    cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,credit_profit=excluded.credit_profit,
    creditor_amount=excluded.creditor_amount,purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,
    purchase_credit=excluded.purchase_credit,total_purchases=excluded.total_purchases,
    pre_stock_purchases=excluded.pre_stock_purchases,sales_returns=excluded.sales_returns,
    purchase_returns=excluded.purchase_returns,sales_return_profit_impact=excluded.sales_return_profit_impact,updated_at=now();
end;
$$;
revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;

create or replace function public.returns_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_shop text; v_date date;
begin
 v_shop:=coalesce(new.shop_id,old.shop_id); v_date:=public.business_date(coalesce(new.returned_at,old.returned_at));
 perform public.refresh_daily_financial_summary(v_shop,v_date);
 perform public.refresh_lifetime_financial_summary(v_shop);
 return coalesce(new,old);
end; $$;
drop trigger if exists returns_financial_aggregate_trigger on public.returns;
create trigger returns_financial_aggregate_trigger after insert or update or delete on public.returns
for each row execute function public.returns_financial_aggregate_trigger();

alter table public.returns enable row level security;
drop policy if exists "returns owner read" on public.returns;
create policy "returns owner read" on public.returns for select to authenticated using ((select public.is_owner()));
grant select on public.returns to authenticated;

-- Keep purchase and sales aggregate triggers on the configured business day.
create or replace function public.sales_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_shop text;
begin
 select shop_id into v_shop from public.profiles where id=coalesce(new.worker_id,old.worker_id);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.sold_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.sold_at)); end if;
 perform public.refresh_lifetime_financial_summary(v_shop); return coalesce(new,old);
end; $$;

create or replace function public.purchase_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_shop text;
begin
 select shop_id into v_shop from public.profiles where id=coalesce(new.purchased_by,old.purchased_by);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.purchased_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.purchased_at)); end if;
 perform public.refresh_lifetime_financial_summary(v_shop); return coalesce(new,old);
end; $$;



-- ============================================================
-- FINAL REPAIR BLOCK — debtor ledger + complete financial summary
-- Must run before the final aggregate rebuild.
-- ============================================================

create table if not exists public.debtors (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  name text not null,
  mobile text,
  mobile_normalized text not null default '',
  address text,
  notes text not null default '',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.debtors add column if not exists mobile_normalized text not null default '';
alter table public.debtors add column if not exists address text;
alter table public.debtors add column if not exists notes text not null default '';
alter table public.debtors add column if not exists is_active boolean not null default true;
alter table public.debtors add column if not exists created_at timestamptz not null default now();
alter table public.debtors add column if not exists updated_at timestamptz not null default now();
update public.debtors
set mobile_normalized=case
  when regexp_replace(coalesce(mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end;

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

-- Backfill one credit-purchase ledger row for every historical purchase that
-- already has a debtor and outstanding credit.
insert into public.debtor_ledger(
  shop_id,debtor_id,purchase_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes,created_at
)
select
  pp.shop_id,
  pr.debtor_id,
  pr.id,
  'credit_purchase',
  pr.credit_amount,
  'credit',
  0,
  0,
  pr.purchased_by,
  'Backfilled credit purchase',
  pr.purchased_at
from public.inventory_purchases pr
join public.profiles pp on pp.id=pr.purchased_by
where pr.debtor_id is not null
  and coalesce(pr.credit_amount,0)>0
  and not exists (
    select 1 from public.debtor_ledger dl
    where dl.purchase_id=pr.id and dl.type='credit_purchase'
  );



create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Keep debtor payments in the same permanent daily aggregate.
create or replace function public.debtor_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_shop text;
  v_tz text;
  v_date date;
begin
  v_shop:=coalesce(new.shop_id,old.shop_id);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  v_date:=(coalesce(new.created_at,old.created_at) at time zone v_tz)::date;
  perform public.refresh_daily_financial_summary(v_shop,v_date);
  return coalesce(new,old);
end;
$$;

drop trigger if exists debtor_financial_aggregate_trigger on public.debtor_ledger;
create trigger debtor_financial_aggregate_trigger
after insert or update or delete on public.debtor_ledger
for each row execute function public.debtor_financial_aggregate_trigger();



-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


update public.debtors
set mobile_normalized = case
  when regexp_replace(coalesce(mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}
create index if not exists debtors_shop_name_idx on public.debtors(shop_id,lower(name));
create index if not exists debtors_shop_active_idx on public.debtors(shop_id,is_active);
create unique index if not exists debtors_shop_mobile_uidx
  on public.debtors(shop_id,mobile_normalized)
  where is_active=true and mobile_normalized<>'';

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;

 then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end;
create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

-- Backfill one credit-purchase ledger row for every historical purchase that
-- already has a debtor and outstanding credit.
insert into public.debtor_ledger(
  shop_id,debtor_id,purchase_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes,created_at
)
select
  pp.shop_id,
  pr.debtor_id,
  pr.id,
  'credit_purchase',
  pr.credit_amount,
  'credit',
  0,
  0,
  pr.purchased_by,
  'Backfilled credit purchase',
  pr.purchased_at
from public.inventory_purchases pr
join public.profiles pp on pp.id=pr.purchased_by
where pr.debtor_id is not null
  and coalesce(pr.credit_amount,0)>0
  and not exists (
    select 1 from public.debtor_ledger dl
    where dl.purchase_id=pr.id and dl.type='credit_purchase'
  );



create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Keep debtor payments in the same permanent daily aggregate.
create or replace function public.debtor_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_shop text;
  v_tz text;
  v_date date;
begin
  v_shop:=coalesce(new.shop_id,old.shop_id);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  v_date:=(coalesce(new.created_at,old.created_at) at time zone v_tz)::date;
  perform public.refresh_daily_financial_summary(v_shop,v_date);
  return coalesce(new,old);
end;
$$;

drop trigger if exists debtor_financial_aggregate_trigger on public.debtor_ledger;
create trigger debtor_financial_aggregate_trigger
after insert or update or delete on public.debtor_ledger
for each row execute function public.debtor_financial_aggregate_trigger();



-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


    then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end
where coalesce(mobile_normalized,'')='';
create index if not exists debtors_shop_name_idx on public.debtors(shop_id,lower(name));
create index if not exists debtors_shop_active_idx on public.debtors(shop_id,is_active);
create unique index if not exists debtors_shop_mobile_uidx
  on public.debtors(shop_id,mobile_normalized)
  where is_active=true and mobile_normalized<>'';

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


    then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end
where coalesce(mobile_normalized,'')='';
create index if not exists debtors_shop_name_idx on public.debtors(shop_id,lower(name));
create index if not exists debtors_shop_active_idx on public.debtors(shop_id,is_active);
create unique index if not exists debtors_shop_mobile_uidx
  on public.debtors(shop_id,mobile_normalized)
  where is_active=true and mobile_normalized<>'';

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;

 then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end;
create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

-- Backfill one credit-purchase ledger row for every historical purchase that
-- already has a debtor and outstanding credit.
insert into public.debtor_ledger(
  shop_id,debtor_id,purchase_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes,created_at
)
select
  pp.shop_id,
  pr.debtor_id,
  pr.id,
  'credit_purchase',
  pr.credit_amount,
  'credit',
  0,
  0,
  pr.purchased_by,
  'Backfilled credit purchase',
  pr.purchased_at
from public.inventory_purchases pr
join public.profiles pp on pp.id=pr.purchased_by
where pr.debtor_id is not null
  and coalesce(pr.credit_amount,0)>0
  and not exists (
    select 1 from public.debtor_ledger dl
    where dl.purchase_id=pr.id and dl.type='credit_purchase'
  );



create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Keep debtor payments in the same permanent daily aggregate.
create or replace function public.debtor_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_shop text;
  v_tz text;
  v_date date;
begin
  v_shop:=coalesce(new.shop_id,old.shop_id);
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;
  v_date:=(coalesce(new.created_at,old.created_at) at time zone v_tz)::date;
  perform public.refresh_daily_financial_summary(v_shop,v_date);
  return coalesce(new,old);
end;
$$;

drop trigger if exists debtor_financial_aggregate_trigger on public.debtor_ledger;
create trigger debtor_financial_aggregate_trigger
after insert or update or delete on public.debtor_ledger
for each row execute function public.debtor_financial_aggregate_trigger();



-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


    then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end
where coalesce(mobile_normalized,'')='';
create index if not exists debtors_shop_name_idx on public.debtors(shop_id,lower(name));
create index if not exists debtors_shop_active_idx on public.debtors(shop_id,is_active);
create unique index if not exists debtors_shop_mobile_uidx
  on public.debtors(shop_id,mobile_normalized)
  where is_active=true and mobile_normalized<>'';

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null,
  amount numeric(14,2) not null,
  payment_mode text,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  worker_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

alter table public.debtor_ledger add column if not exists purchase_id uuid references public.inventory_purchases(id) on delete set null;
alter table public.debtor_ledger add column if not exists payment_mode text;
alter table public.debtor_ledger add column if not exists cash_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists upi_amount numeric(14,2) not null default 0;
alter table public.debtor_ledger add column if not exists worker_id uuid references public.profiles(id) on delete set null;
alter table public.debtor_ledger add column if not exists notes text not null default '';
alter table public.debtor_ledger add column if not exists created_at timestamptz not null default now();

create index if not exists debtor_ledger_shop_date_idx on public.debtor_ledger(shop_id,created_at desc);
create index if not exists debtor_ledger_debtor_date_idx on public.debtor_ledger(debtor_id,created_at desc);

alter table public.debtors enable row level security;
alter table public.debtor_ledger enable row level security;

drop policy if exists debtors_shop_read on public.debtors;
create policy debtors_shop_read on public.debtors
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists debtor_ledger_shop_read on public.debtor_ledger;
create policy debtor_ledger_shop_read on public.debtor_ledger
for select to authenticated
using (shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

grant select on public.debtors to authenticated;
grant select on public.debtor_ledger to authenticated;

create or replace function public.normalize_debtor_mobile(p_mobile text)
returns text language sql immutable set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$' then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end;
$$;

-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;


create or replace function public.get_or_create_debtor(p_name text,p_mobile text)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then raise exception 'Shop ID is not configured'; end if;
  v_mobile:=public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile)<10 then raise exception 'Enter a valid mobile number'; end if;
  if btrim(coalesce(p_name,''))='' then raise exception 'Debtor name is required'; end if;

  select * into r from public.debtors
  where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
  order by created_at limit 1 for update;

  if found then
    update public.debtors set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at limit 1;
  end;
  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
)
returns public.debtors
language plpgsql security definer set search_path=''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
    from public.debtor_ledger where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values(
    v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment'
  );

  v_remaining:=p_amount;
  for r in
    select id,credit_amount,credit_paid
    from public.inventory_purchases
    where debtor_id=p_debtor_id
      and purchased_by in (select id from public.profiles where shop_id=v_shop)
      and coalesce(pre_stock,false)=false
      and credit_amount>credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining<=0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Preserve the original product name for all historical rows where the product still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (s.product_name_snapshot is null or btrim(s.product_name_snapshot)='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (i.product_name_snapshot is null or btrim(i.product_name_snapshot)='' or i.product_name_snapshot='Deleted product');

create or replace function public.refresh_daily_financial_summary(p_shop_id text,p_business_date date)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz from public.shop_settings where id=1;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,
    coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),
    round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),
    round(coalesce(d.pay_upi,0),2),
    round(coalesce(d.pay_total,0),2),
    now()
  from (select 1) seed
  left join lateral (
    select
      count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0 then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and (dl.created_at at time zone v_tz)::date=p_business_date
  ) d on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,updated_at=now();
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select p_shop_id,coalesce(sum(total_revenue),0),coalesce(sum(total_purchases+pre_stock_purchases),0),coalesce(sum(total_profit),0),now()
  from public.daily_financial_summaries where shop_id=p_shop_id
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

revoke all on function public.refresh_lifetime_financial_summary(text) from public,anon,authenticated;
grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- Rebuild permanent aggregates using the configured business-day reset after
-- all patched functions/triggers are installed.
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, public.business_date(s.sold_at) business_date
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct w.shop_id, public.business_date(p.purchased_at) business_date
    from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct d.shop_id, public.business_date(d.created_at) business_date
    from public.debtor_ledger d
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in
    select distinct ret.shop_id, public.business_date(ret.returned_at) business_date
    from public.returns ret
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
  for r in select distinct shop_id from public.daily_financial_summaries
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end $$;


-- FINAL SCHEMA SAFETY REPAIR: automatic day-end snapshot storage.
create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);


-- FINAL SAFE CLEAR-ALL RPC (unique name; avoids legacy function versions)
create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs',
    'products',
    'debtors',
    'creditors'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  /*
    Keep the existing app usable after Clear All:
    owner/worker profiles, authentication accounts, shop settings and the
    connected Supabase configuration are intentionally preserved.
  */
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[]),
      'products_deleted',true,
      'debtors_deleted',true,
      'creditors_deleted',true
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;

