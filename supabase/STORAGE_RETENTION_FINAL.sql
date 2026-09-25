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
    payment_mode = 'pre_stock'
where payment_mode is null or payment_mode = '';

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
    purchase_cash,purchase_upi,purchase_credit,total_purchases,updated_at
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
        coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric as total_purchase
      from public.inventory_purchases i
      join public.profiles w on w.id=i.purchased_by
      where w.shop_id=p_shop_id
        and coalesce(i.pre_stock,false)=false
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
    coalesce(sum(total_purchases),0),
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
    where w.shop_id is not null and coalesce(i.pre_stock,false)=false
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
    get diagnostics v_credit_deleted=v_credit_deleted+row_count;
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
  sid text;
begin
  select shop_id into sid from public.shop_settings where id=1;
  if to_regclass('public.profiles') is null then missing:=array_append(missing,'profiles'); end if;
  if to_regclass('public.products') is null then missing:=array_append(missing,'products'); end if;
  if to_regclass('public.sales') is null then missing:=array_append(missing,'sales'); end if;
  if to_regclass('public.inventory_purchases') is null then missing:=array_append(missing,'inventory_purchases'); end if;
  if to_regclass('public.creditors') is null then missing:=array_append(missing,'creditors'); end if;
  if to_regclass('public.credit_ledger') is null then missing:=array_append(missing,'credit_ledger'); end if;
  if to_regclass('public.daily_financial_summaries') is null then missing:=array_append(missing,'daily_financial_summaries'); end if;
  if to_regclass('public.lifetime_financial_summaries') is null then missing:=array_append(missing,'lifetime_financial_summaries'); end if;
  if to_regclass('public.audit_logs') is null then missing:=array_append(missing,'audit_logs'); end if;
  return jsonb_build_object('ok',cardinality(missing)=0,'shop_id',sid,'missing',to_jsonb(missing));
end;
$$;

revoke all on function public.verify_shop_management(text) from public;
grant execute on function public.verify_shop_management(text) to authenticated;

create or replace function public.clear_all_shop_data()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  delete from public.credit_ledger;
  delete from public.sales;
  delete from public.sale_transactions;
  delete from public.inventory_purchases;
  delete from public.audit_logs;
  delete from public.daily_financial_summaries;
  delete from public.lifetime_financial_summaries;
  delete from public.creditor_daily_financial_aggregates;
  update public.products set current_stock_base=0,updated_at=now();
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values((select auth.uid()),'clear_all','shop','{}'::jsonb);
end;
$$;

revoke all on function public.clear_all_shop_data() from public,anon;
grant execute on function public.clear_all_shop_data() to authenticated;

-- ============================================================
-- 11. RLS / grants for permanent aggregates
-- ============================================================
alter table public.daily_financial_summaries enable row level security;
alter table public.lifetime_financial_summaries enable row level security;
alter table public.creditor_daily_financial_aggregates enable row level security;

revoke all on table public.daily_financial_summaries from anon;
revoke all on table public.lifetime_financial_summaries from anon;
revoke all on table public.creditor_daily_financial_aggregates from anon;

grant select on public.daily_financial_summaries to authenticated;
grant select on public.lifetime_financial_summaries to authenticated;
grant select on public.creditor_daily_financial_aggregates to authenticated;

drop policy if exists "daily financial same shop" on public.daily_financial_summaries;
create policy "daily financial same shop" on public.daily_financial_summaries
for select to authenticated
using ((select public.is_active_user()) and shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists "lifetime financial same shop" on public.lifetime_financial_summaries;
create policy "lifetime financial same shop" on public.lifetime_financial_summaries
for select to authenticated
using ((select public.is_active_user()) and shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

drop policy if exists "creditor aggregate same shop" on public.creditor_daily_financial_aggregates;
create policy "creditor aggregate same shop" on public.creditor_daily_financial_aggregates
for select to authenticated
using ((select public.is_active_user()) and shop_id=(select shop_id from public.profiles where id=(select auth.uid())));

-- ============================================================
-- 12. PostgreSQL/Supabase automatic cleanup
-- ============================================================
-- Supabase Cron runs inside Postgres, so retention is not dependent on the
-- Android app being opened. The job is scheduled daily at 03:30 UTC.
do $$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron could not be enabled automatically. Enable Supabase Cron/pg_cron in Database > Extensions, then run the schedule block below.';
  end;

  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'shop-management-storage-retention',
      '30 3 * * *',
      'select public.run_storage_retention_cleanup();'
    );
    perform cron.schedule(
      'shop-management-cron-log-cleanup',
      '0 4 * * *',
      'delete from cron.job_run_details where end_time < now() - interval ''7 days'';'
    );
  end if;
exception when others then
  raise notice 'Storage retention functions are installed, but cron scheduling needs to be enabled/configured in Supabase Cron.';
end;
$$;

select pg_notify('pgrst','reload schema');
