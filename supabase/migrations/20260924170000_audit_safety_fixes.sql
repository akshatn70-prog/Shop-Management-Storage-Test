-- Safety/reliability patch for existing installations.
-- Does not change the current automatic sale -> stock -> day-end/closing UI flow.

alter table public.shop_settings
  add column if not exists allow_below_cost_sales boolean not null default true,
  add column if not exists allow_zero_price_sales boolean not null default true;

alter table public.day_end_summaries
  add column if not exists expected_total numeric(14,2) not null default 0,
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;

alter table public.day_end_summaries drop constraint if exists day_end_payment_split_check;
alter table public.day_end_summaries
  add constraint day_end_payment_split_check
  check (expected_total >= 0 and cash_amount >= 0 and upi_amount >= 0 and cash_amount + upi_amount = expected_total);

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
drop trigger if exists protect_product_stock_direct_update on public.products;
create trigger protect_product_stock_direct_update before update on public.products
for each row execute function public.protect_product_stock_direct_update();

revoke insert on public.inventory_purchases from authenticated;

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


create or replace function public.add_inventory_purchase(
  p_product_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_purchase_unit text,
  p_purchase_price numeric
) returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.products; total numeric;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_quantity_display<=0 or p_purchase_price<0 then raise exception 'Invalid purchase'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if mod(p_quantity_base,1)<>0 or p_purchase_unit<>'piece' or p_quantity_display<>p_quantity_base then raise exception 'Piece purchases must use whole pieces'; end if;
  else
    if p_purchase_unit not in ('grams','kg') then raise exception 'Weight purchases must use grams or kg'; end if;
    if p_purchase_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg purchase quantity'; end if;
    if p_purchase_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram purchase quantity'; end if;
  end if;
  total:=case when p.unit_type='weight' then (p_quantity_base/1000)*p_purchase_price else p_quantity_base*p_purchase_price end;
  insert into public.inventory_purchases(product_id,quantity_base,quantity_display,purchase_unit,purchase_price_per_base_unit,total_cost,purchased_by)
  values(p_product_id,p_quantity_base,p_quantity_display,p_purchase_unit,p_purchase_price,total,(select auth.uid()));
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base+p_quantity_base,purchase_price_per_base_unit=p_purchase_price,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  perform public.write_audit('purchase_added','product',p_product_id,jsonb_build_object('quantity_base',p_quantity_base,'quantity_display',p_quantity_display,'unit',p_purchase_unit,'purchase_price',p_purchase_price,'total_cost',total));
end;
$$;
revoke execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric) from public, anon;
grant execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric) to authenticated;

-- Repair the legacy closing RPC: difference is a generated column and must never be written.
create or replace function public.submit_daily_closing(p_business_date date,p_cash numeric,p_upi numeric,p_closing_id uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare closing_id uuid; expected numeric; current_status public.closing_status; shop_tz text;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if not exists(select 1 from public.profiles where id=(select auth.uid()) and role='worker' and is_active=true) then raise exception 'Only an active worker can submit a closing'; end if;
  if p_cash<0 or p_upi<0 then raise exception 'Cash and UPI cannot be negative'; end if;
  select timezone into shop_tz from public.shop_settings where id=1;
  select coalesce(sum(s.total_sale),0) into expected from public.sales s
  where s.worker_id=(select auth.uid()) and s.voided=false and (s.sold_at at time zone coalesce(shop_tz,'Asia/Kolkata'))::date=p_business_date;
  if p_closing_id is not null then
    select id,status into closing_id,current_status from public.daily_closings where id=p_closing_id and worker_id=(select auth.uid()) for update;
    if closing_id is null then raise exception 'Closing not found'; end if;
    if current_status in ('approved','locked') then raise exception 'Closing is already finalized'; end if;
    update public.daily_closings set business_date=p_business_date,expected_total=expected,cash_amount=p_cash,upi_amount=p_upi,status='submitted',submitted_at=now() where id=closing_id;
  else
    select id,status into closing_id,current_status from public.daily_closings where worker_id=(select auth.uid()) and business_date=p_business_date for update;
    if closing_id is not null and current_status in ('approved','locked') then raise exception 'Closing is already finalized'; end if;
    if closing_id is null then
      insert into public.daily_closings(worker_id,business_date,expected_total,cash_amount,upi_amount,status,submitted_at)
      values((select auth.uid()),p_business_date,expected,p_cash,p_upi,'submitted',now()) returning id into closing_id;
    else
      update public.daily_closings set expected_total=expected,cash_amount=p_cash,upi_amount=p_upi,status='submitted',submitted_at=now() where id=closing_id;
    end if;
  end if;
  perform public.write_audit('closing_submitted','daily_closing',closing_id,jsonb_build_object('business_date',p_business_date,'expected_total',expected,'cash',p_cash,'upi',p_upi));
  return closing_id;
end;
$$;

-- Day-end RPCs need definer rights because authenticated users intentionally have read-only access to closings.
alter function public.submit_day_end_summary(uuid) security definer;
alter function public.confirm_day_end_summary(uuid) security definer;

do $$ begin alter publication supabase_realtime add table public.inventory_purchases; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.day_end_summary_lines; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.audit_logs; exception when duplicate_object then null; when undefined_object then null; end $$;


-- Direct table updates are only for a worker's own draft. Owner finalization uses protected RPCs.
drop policy if exists "day end update draft" on public.day_end_summaries;
create policy "day end update draft" on public.day_end_summaries for update to authenticated
using (worker_id=(select auth.uid()) and status='draft')
with check ((select public.is_active_user()) and worker_id=(select auth.uid()) and status='draft');

-- Preserve an audit marker when the owner uses Start over. Transaction history is still cleared as requested.
create or replace function public.clear_all_shop_data()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  perform public.write_audit('shop_data_cleared','shop',null,jsonb_build_object('cleared_at',now()));
  truncate table public.day_end_summary_lines,public.day_end_summaries,public.daily_closings,public.sales,public.inventory_purchases,public.automatic_day_end_snapshots restart identity;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=0,updated_at=now() where id is not null;
  perform set_config('shop.allow_stock_change','off',true);
end;
$$;
revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;


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
alter table public.automatic_day_end_snapshots enable row level security;
grant select on public.automatic_day_end_snapshots to authenticated;
drop policy if exists "snapshot select" on public.automatic_day_end_snapshots;
create policy "snapshot select" on public.automatic_day_end_snapshots for select to authenticated
using ((select public.is_active_user()));

create or replace function public.refresh_automatic_day_end_snapshot(p_business_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare tz text; product_json jsonb; worker_json jsonb;
begin
  select timezone into tz from public.shop_settings where id=1;
  select coalesce(jsonb_agg(x order by x->>'product'), '[]'::jsonb) into product_json
  from (
    select jsonb_build_object('product',coalesce(p.name,'Unknown'),'quantity_base',sum(s.quantity_base),'revenue',round(sum(s.total_sale),2),'profit',round(sum(s.gross_profit),2)) x
    from public.sales s left join public.products p on p.id=s.product_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(p.name,'Unknown')
  ) q;
  select coalesce(jsonb_agg(x order by x->>'worker'), '[]'::jsonb) into worker_json
  from (
    select jsonb_build_object('worker',coalesce(pr.full_name,'Worker'),'transactions',count(*),'revenue',round(sum(s.total_sale),2),'profit',round(sum(s.gross_profit),2),'cash',round(sum(s.cash_amount),2),'upi',round(sum(s.upi_amount),2)) x
    from public.sales s left join public.profiles pr on pr.id=s.worker_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(pr.full_name,'Worker')
  ) q;
  insert into public.automatic_day_end_snapshots(business_date,total_sales,total_cost,total_profit,transactions,cash_amount,upi_amount,product_breakdown,worker_breakdown,updated_at)
  select p_business_date,coalesce(sum(s.total_sale),0),coalesce(sum(s.total_cost),0),coalesce(sum(s.gross_profit),0),count(*),coalesce(sum(s.cash_amount),0),coalesce(sum(s.upi_amount),0),coalesce(product_json,'[]'::jsonb),coalesce(worker_json,'[]'::jsonb),now()
  from public.sales s where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
  on conflict (business_date) do update set total_sales=excluded.total_sales,total_cost=excluded.total_cost,total_profit=excluded.total_profit,transactions=excluded.transactions,cash_amount=excluded.cash_amount,upi_amount=excluded.upi_amount,product_breakdown=excluded.product_breakdown,worker_breakdown=excluded.worker_breakdown,updated_at=now();
end;
$$;
revoke execute on function public.refresh_automatic_day_end_snapshot(date) from public,anon,authenticated;

create or replace function public.refresh_automatic_day_end_snapshot_trigger()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare tz text; d date;
begin
  select timezone into tz from public.shop_settings where id=1;
  d=(coalesce(NEW.sold_at,OLD.sold_at) at time zone coalesce(tz,'Asia/Kolkata'))::date;
  perform public.refresh_automatic_day_end_snapshot(d);
  return NEW;
end;
$$;
revoke execute on function public.refresh_automatic_day_end_snapshot_trigger() from public,anon,authenticated;
drop trigger if exists sales_refresh_automatic_day_end_snapshot on public.sales;
create trigger sales_refresh_automatic_day_end_snapshot after insert or update of voided on public.sales
for each row execute function public.refresh_automatic_day_end_snapshot_trigger();

