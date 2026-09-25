-- ============================================================
-- STORAGE-EFFICIENT SHOP MANAGEMENT RETENTION
-- Test branch only. Run after the existing Shop Management SQL.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.daily_financial_summaries (
  shop_id text not null,
  business_date date not null,
  total_transactions integer not null default 0,
  total_revenue numeric(16,2) not null default 0,
  cash_sales numeric(16,2) not null default 0,
  upi_sales numeric(16,2) not null default 0,
  credit_sales numeric(16,2) not null default 0,
  total_profit numeric(16,2) not null default 0,
  cash_profit numeric(16,2) not null default 0,
  upi_profit numeric(16,2) not null default 0,
  credit_profit numeric(16,2) not null default 0,
  creditor_amount numeric(16,2) not null default 0,
  credit_payments_cash numeric(16,2) not null default 0,
  credit_payments_upi numeric(16,2) not null default 0,
  total_purchases numeric(16,2) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (shop_id,business_date)
);

create table if not exists public.lifetime_financial_summaries (
  shop_id text primary key,
  lifetime_sales numeric(18,2) not null default 0,
  lifetime_purchases numeric(18,2) not null default 0,
  lifetime_profit numeric(18,2) not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.creditor_retention (
  creditor_id uuid primary key references public.creditors(id) on delete cascade,
  zero_balance_since timestamptz
);

alter table public.daily_financial_summaries enable row level security;
alter table public.lifetime_financial_summaries enable row level security;
alter table public.creditor_retention enable row level security;

drop policy if exists daily_financial_owner_read on public.daily_financial_summaries;
create policy daily_financial_owner_read on public.daily_financial_summaries
for select to authenticated using (public.is_owner());

drop policy if exists lifetime_financial_owner_read on public.lifetime_financial_summaries;
create policy lifetime_financial_owner_read on public.lifetime_financial_summaries
for select to authenticated using (public.is_owner());

create index if not exists daily_financial_shop_date_idx
  on public.daily_financial_summaries(shop_id,business_date desc);
create index if not exists creditor_retention_zero_idx
  on public.creditor_retention(zero_balance_since);

create or replace function public.refresh_financial_aggregates(p_shop_id text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop text := coalesce(nullif(p_shop_id,''),(select shop_id from public.shop_settings where id=1));
begin
  if v_shop is null or v_shop='' then return; end if;

  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,total_purchases,updated_at
  )
  select
    v_shop,
    (s.sold_at at time zone coalesce((select timezone from public.shop_settings where id=1),'Asia/Kolkata'))::date,
    count(distinct coalesce(s.transaction_id,s.id)),
    coalesce(sum(s.total_sale),0),
    coalesce(sum(case when s.payment_mode in ('cash','split') then s.cash_amount else 0 end),0),
    coalesce(sum(case when s.payment_mode in ('upi','split') then s.upi_amount else 0 end),0),
    coalesce(sum(case when st.payment_mode in ('credit','credit_split') then greatest(0,st.total-st.cash_amount-st.upi_amount) else 0 end),0),
    0,\n    0,
    coalesce(sum(s.gross_profit),0),
    coalesce(sum(case when st.payment_mode='cash' then s.gross_profit when st.payment_mode='split' then s.gross_profit*(case when st.total>0 then st.cash_amount/st.total else 0 end) else 0 end),0),
    coalesce(sum(case when st.payment_mode='upi' then s.gross_profit when st.payment_mode='split' then s.gross_profit*(case when st.total>0 then st.upi_amount/st.total else 0 end) else 0 end),0),
    coalesce(sum(case when st.payment_mode in ('credit','credit_split') then s.gross_profit*(case when st.total>0 then greatest(0,st.total-st.cash_amount-st.upi_amount)/st.total else 0 end) else 0 end),0),
    coalesce(sum(case when st.payment_mode in ('credit','credit_split') then greatest(0,st.total-st.cash_amount-st.upi_amount) else 0 end),0),
    coalesce((select sum(ip.total_cost) from public.inventory_purchases ip
      where ip.purchased_at >= ((s.sold_at at time zone coalesce((select timezone from public.shop_settings where id=1),'Asia/Kolkata'))::date)::timestamptz
        and ip.purchased_at < (((s.sold_at at time zone coalesce((select timezone from public.shop_settings where id=1),'Asia/Kolkata'))::date)+1)::timestamptz),0),
    now()
  from public.sales s
  left join public.sale_transactions st on st.id=s.transaction_id
  where s.voided=false
  group by 2
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    credit_payments_cash=excluded.credit_payments_cash,credit_payments_upi=excluded.credit_payments_upi,
    total_purchases=public.daily_financial_summaries.total_purchases,
    updated_at=now();

  insert into public.daily_financial_summaries(shop_id,business_date,credit_payments_cash,credit_payments_upi,updated_at)
  select v_shop,
    (cl.created_at at time zone coalesce((select timezone from public.shop_settings where id=1),'Asia/Kolkata'))::date,
    coalesce(sum(cl.cash_amount),0),coalesce(sum(cl.upi_amount),0),now()
  from public.credit_ledger cl
  where cl.type='payment_received'
  group by 2
  on conflict(shop_id,business_date) do update set
    credit_payments_cash=excluded.credit_payments_cash,
    credit_payments_upi=excluded.credit_payments_upi,
    updated_at=now();

  insert into public.daily_financial_summaries(shop_id,business_date,total_purchases,updated_at)
  select v_shop,
    (ip.purchased_at at time zone coalesce((select timezone from public.shop_settings where id=1),'Asia/Kolkata'))::date,
    coalesce(sum(ip.total_cost),0),now()
  from public.inventory_purchases ip
  group by 2
  on conflict(shop_id,business_date) do update set total_purchases=excluded.total_purchases,updated_at=now();

  insert into public.lifetime_financial_summaries(shop_id,lifetime_sales,lifetime_purchases,lifetime_profit,updated_at)
  select v_shop,
    coalesce((select sum(total_revenue) from public.daily_financial_summaries where shop_id=v_shop),0),
    coalesce((select sum(total_purchases) from public.daily_financial_summaries where shop_id=v_shop),0),
    coalesce((select sum(total_profit) from public.daily_financial_summaries where shop_id=v_shop),0),
    now()
  on conflict(shop_id) do update set
    lifetime_sales=excluded.lifetime_sales,
    lifetime_purchases=excluded.lifetime_purchases,
    lifetime_profit=excluded.lifetime_profit,
    updated_at=now();
end;
$$;

create or replace function public.cleanup_old_shop_detail()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop text := (select shop_id from public.shop_settings where id=1);
  v_sales integer := 0;
  v_purchases integer := 0;
  v_audit integer := 0;
  v_credit integer := 0;
begin
  perform public.refresh_financial_aggregates(v_shop);

  with old_transactions as (
    select distinct s.transaction_id
    from public.sales s
    where s.sold_at < now()-interval '90 days'
  )
  delete from public.credit_ledger cl
  where cl.sale_transaction_id in (select transaction_id from old_transactions)
    and cl.type='credit_sale'
    and not exists (
      select 1 from public.creditors c
      where c.id=cl.creditor_id
        and coalesce((select sum(case when x.type in ('credit_sale','adjustment') then x.amount else -x.amount end)
                      from public.credit_ledger x where x.creditor_id=c.id),0) > 0
    );
  delete from public.sales where sold_at < now()-interval '90 days';
  get diagnostics v_sales = row_count;

  delete from public.sale_transactions st
  where st.created_at < now()-interval '90 days'
    and not exists (select 1 from public.sales s where s.transaction_id=st.id)
    and not exists (select 1 from public.credit_ledger cl where cl.sale_transaction_id=st.id);
  delete from public.inventory_purchases where purchased_at < now()-interval '1 year';
  get diagnostics v_purchases = row_count;

  delete from public.audit_logs where created_at < now()-interval '30 days';
  get diagnostics v_audit = row_count;

  insert into public.creditor_retention(creditor_id,zero_balance_since)
  select c.id,now()
  from public.creditors c
  where coalesce((select sum(case when cl.type in ('credit_sale','adjustment') then cl.amount else -cl.amount end)
                  from public.credit_ledger cl where cl.creditor_id=c.id),0) <= 0
  on conflict(creditor_id) do nothing;

  update public.creditor_retention r
  set zero_balance_since=null
  where coalesce((select sum(case when cl.type in ('credit_sale','adjustment') then cl.amount else -cl.amount end)
                  from public.credit_ledger cl where cl.creditor_id=r.creditor_id),0) > 0;

  delete from public.credit_ledger cl
  using public.creditor_retention r
  where r.creditor_id=cl.creditor_id
    and r.zero_balance_since is not null
    and r.zero_balance_since < now()-interval '7 days';

  get diagnostics v_credit = row_count;

  perform public.refresh_financial_aggregates(v_shop);

  return jsonb_build_object('sales_deleted',v_sales,'purchases_deleted',v_purchases,'audit_deleted',v_audit,'credit_detail_deleted',v_credit);
end;
$$;

revoke all on function public.cleanup_old_shop_detail() from public,anon,authenticated;
grant execute on function public.cleanup_old_shop_detail() to authenticated;
revoke all on function public.refresh_financial_aggregates(text) from public,anon,authenticated;
grant execute on function public.refresh_financial_aggregates(text) to authenticated;

-- Run cleanup automatically at database level when pg_cron is available.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('shop-management-retention','15 2 * * *','select public.cleanup_old_shop_detail();');
exception when others then
  raise notice 'pg_cron could not be enabled automatically: %',sqlerrm;
end;
$$;

-- Remove obsolete day-closing data after aggregate migration. These objects are no longer used by the redesigned UI.
-- Kept commented intentionally: run manually only after verifying the new UI in this test project.
-- drop table if exists public.day_end_summary_lines cascade;
-- drop table if exists public.day_end_summaries cascade;
-- drop table if exists public.daily_closings cascade;
-- drop table if exists public.automatic_day_end_snapshots cascade;
