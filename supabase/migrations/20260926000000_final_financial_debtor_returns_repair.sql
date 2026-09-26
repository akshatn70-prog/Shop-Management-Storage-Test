-- ============================================================
-- 20260926000000 — FINAL FINANCIAL / DEBTOR / RETURNS REPAIR
-- Fixes:
-- 1) missing debtor RPC/table support
-- 2) purchase/sale return aggregate failures
-- 3) missing daily financial summary payment columns
-- 4) incorrect/stale daily and lifetime reports
-- 5) debtor payments in reports
-- 6) historical product-name snapshots
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- DEBTORS
-- ------------------------------------------------------------
create table if not exists public.debtors (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  name text not null,
  mobile text not null,
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
set mobile_normalized = case
  when regexp_replace(coalesce(mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$'
    then right(regexp_replace(coalesce(mobile,''),'[^0-9]','','g'),10)
  else regexp_replace(coalesce(mobile,''),'[^0-9]','','g')
end
where coalesce(mobile_normalized,'')='';

create index if not exists debtors_shop_name_idx on public.debtors(shop_id, lower(name));
create index if not exists debtors_shop_active_idx on public.debtors(shop_id,is_active);
create unique index if not exists debtors_shop_mobile_uidx
  on public.debtors(shop_id,mobile_normalized)
  where is_active=true and mobile_normalized<>'';

create table if not exists public.debtor_ledger (
  id uuid primary key default gen_random_uuid(),
  shop_id text not null,
  debtor_id uuid not null references public.debtors(id) on delete cascade,
  purchase_id uuid references public.inventory_purchases(id) on delete set null,
  type text not null check (type in ('credit_purchase','payment_made','adjustment')),
  amount numeric(14,2) not null check (amount > 0),
  payment_mode text,
  cash_amount numeric(14,2) not null default 0 check (cash_amount >= 0),
  upi_amount numeric(14,2) not null default 0 check (upi_amount >= 0),
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
create index if not exists debtor_ledger_purchase_idx on public.debtor_ledger(purchase_id);

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
returns text
language sql
immutable
set search_path=''
as $$
  select case
    when regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g') ~ '^91[0-9]{10}$'
      then right(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g'),10)
    else regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')
  end
$$;

revoke all on function public.normalize_debtor_mobile(text) from public,anon,authenticated;

create or replace function public.get_or_create_debtor(
  p_name text,
  p_mobile text
)
returns public.debtors
language plpgsql
security definer
set search_path=''
as $$
declare
  v_shop text;
  v_mobile text;
  r public.debtors;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;

  v_shop := (select shop_id from public.profiles where id=(select auth.uid()));
  if v_shop is null or btrim(v_shop)='' then
    raise exception 'Shop ID is not configured';
  end if;

  v_mobile := public.normalize_debtor_mobile(p_mobile);
  if length(v_mobile) < 10 then
    raise exception 'Enter a valid mobile number';
  end if;
  if btrim(coalesce(p_name,''))='' then
    raise exception 'Debtor name is required';
  end if;

  select * into r
  from public.debtors
  where shop_id=v_shop
    and mobile_normalized=v_mobile
    and is_active=true
  order by created_at
  limit 1
  for update;

  if found then
    update public.debtors
    set name=btrim(p_name),mobile=btrim(p_mobile),updated_at=now()
    where id=r.id
    returning * into r;
    return r;
  end if;

  begin
    insert into public.debtors(shop_id,name,mobile,mobile_normalized)
    values(v_shop,btrim(p_name),btrim(p_mobile),v_mobile)
    returning * into r;
  exception when unique_violation then
    select * into r
    from public.debtors
    where shop_id=v_shop and mobile_normalized=v_mobile and is_active=true
    order by created_at
    limit 1;
  end;

  return r;
end;
$$;

revoke all on function public.get_or_create_debtor(text,text) from public,anon;
grant execute on function public.get_or_create_debtor(text,text) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,
  p_amount numeric,
  p_payment_mode text default 'cash',
  p_cash_amount numeric default null,
  p_upi_amount numeric default null
)
returns public.debtors
language plpgsql
security definer
set search_path=''
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
  if p_amount <= 0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;

  v_shop := (select shop_id from public.profiles where id=(select auth.uid()));

  select * into d
  from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true
  for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    v_cash:=coalesce(p_cash_amount,0);
    v_upi:=coalesce(p_upi_amount,0);
  end if;

  if v_cash < 0 or v_upi < 0 or abs((v_cash+v_upi)-p_amount) > 0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if p_amount > (
    select coalesce(sum(
      case when type in ('credit_purchase','adjustment') then amount else -amount end
    ),0)
    from public.debtor_ledger
    where debtor_id=p_debtor_id and shop_id=v_shop
  ) + 0.01 then
    raise exception 'Payment exceeds debtor outstanding balance';
  end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes
  ) values (
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
      and credit_amount > credit_paid
    order by purchased_at,id
    for update
  loop
    exit when v_remaining <= 0.01;
    v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
    update public.inventory_purchases
    set credit_paid=credit_paid+v_take
    where id=r.id;
    v_remaining:=v_remaining-v_take;
  end loop;

  perform public.write_audit(
    'debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi)
  );

  return d;
end;
$$;

revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

-- ------------------------------------------------------------
-- DAILY FINANCIAL SUMMARY — COMPLETE CURRENT SHAPE
-- ------------------------------------------------------------
alter table public.daily_financial_summaries
  add column if not exists pre_stock_purchases numeric(14,2) not null default 0,
  add column if not exists sales_returns numeric(14,2) not null default 0,
  add column if not exists purchase_returns numeric(14,2) not null default 0,
  add column if not exists sales_return_profit_impact numeric(14,2) not null default 0,
  add column if not exists debtor_payment_cash numeric(14,2) not null default 0,
  add column if not exists debtor_payment_upi numeric(14,2) not null default 0,
  add column if not exists debtor_payment_total numeric(14,2) not null default 0;

-- Keep the historical name whenever it is still recoverable from the product row.
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

-- ------------------------------------------------------------
-- One authoritative daily aggregate calculation.
-- ------------------------------------------------------------
create or replace function public.refresh_daily_financial_summary(
  p_shop_id text,
  p_business_date date
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_tz text;
begin
  select coalesce(timezone,'Asia/Kolkata') into v_tz
  from public.shop_settings where id=1;

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
      coalesce(sum(
        case when s.payment_mode in ('credit','credit_split')
          then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end
      ),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(
        case when s.payment_mode='cash' then s.gross_profit
        when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale
        else 0 end
      ),0)::numeric cash_profit,
      coalesce(sum(
        case when s.payment_mode='upi' then s.gross_profit
        when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale
        else 0 end
      ),0)::numeric upi_profit,
      coalesce(sum(
        case when s.payment_mode in ('credit','credit_split') and s.total_sale>0
          then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale
        else 0 end
      ),0)::numeric credit_profit
    from public.sales s
    join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id
      and not s.voided
      and (s.sold_at at time zone v_tz)::date=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i
    join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id
      and (i.purchased_at at time zone v_tz)::date=p_business_date
  ) p on true
  left join lateral (
    select
      coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id
      and (dl.created_at at time zone v_tz)::date=p_business_date
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
    where shop_id=p_shop_id
      and (returned_at at time zone v_tz)::date=p_business_date
  ) r on true;

  perform public.refresh_lifetime_financial_summary(p_shop_id);
end;
$$;

revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.refresh_lifetime_financial_summary(p_shop_id text)
returns void
language plpgsql
security definer
set search_path=''
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


grant execute on function public.refresh_lifetime_financial_summary(text) to authenticated;

-- ------------------------------------------------------------
-- Recalculate aggregates after installation.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select distinct w.shop_id, (s.sold_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date as business_date
    from public.sales s
    join public.profiles w on w.id=s.worker_id
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct w.shop_id, (p.purchased_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date as business_date
    from public.inventory_purchases p
    join public.profiles w on w.id=p.purchased_by
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct d.shop_id, (d.created_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date as business_date
    from public.debtor_ledger d
    cross join public.shop_settings st
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct ret.shop_id, (ret.returned_at at time zone coalesce(st.timezone,'Asia/Kolkata'))::date as business_date
    from public.returns ret
    cross join public.shop_settings st
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;
end $$;

select pg_notify('pgrst','reload schema');
