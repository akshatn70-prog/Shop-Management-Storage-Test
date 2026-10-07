-- Financial aggregate trigger repair.
-- Restores the triggers that keep daily/lifetime financial summaries current
-- after sales and purchases. This migration is intentionally non-destructive.

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
  select shop_id
    into v_shop
  from public.profiles
  where id = coalesce(new.worker_id, old.worker_id);

  if v_shop is null then
    return coalesce(new, old);
  end if;

  select coalesce(timezone, 'Asia/Kolkata')
    into v_tz
  from public.shop_settings
  where id = 1;

  if old is not null then
    perform public.refresh_daily_financial_summary(
      v_shop,
      (old.sold_at at time zone v_tz)::date
    );
  end if;

  if new is not null then
    perform public.refresh_daily_financial_summary(
      v_shop,
      (new.sold_at at time zone v_tz)::date
    );
  end if;

  perform public.refresh_lifetime_financial_summary(v_shop);

  return coalesce(new, old);
end;
$$;

drop trigger if exists sales_financial_aggregate_trigger on public.sales;

create trigger sales_financial_aggregate_trigger
after insert or update or delete on public.sales
for each row
execute function public.sales_financial_aggregate_trigger();


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
  select shop_id
    into v_shop
  from public.profiles
  where id = coalesce(new.purchased_by, old.purchased_by);

  if v_shop is null then
    return coalesce(new, old);
  end if;

  select coalesce(timezone, 'Asia/Kolkata')
    into v_tz
  from public.shop_settings
  where id = 1;

  if old is not null then
    perform public.refresh_daily_financial_summary(
      v_shop,
      (old.purchased_at at time zone v_tz)::date
    );
  end if;

  if new is not null then
    perform public.refresh_daily_financial_summary(
      v_shop,
      (new.purchased_at at time zone v_tz)::date
    );
  end if;

  perform public.refresh_lifetime_financial_summary(v_shop);

  return coalesce(new, old);
end;
$$;

drop trigger if exists purchase_financial_aggregate_trigger on public.inventory_purchases;

create trigger purchase_financial_aggregate_trigger
after insert or update or delete on public.inventory_purchases
for each row
execute function public.purchase_financial_aggregate_trigger();


-- Repair any missing/out-of-date summary rows immediately.
do $$
declare
  r record;
begin
  for r in
    select distinct
      w.shop_id,
      (s.sold_at at time zone coalesce(st.timezone, 'Asia/Kolkata'))::date as business_date
    from public.sales s
    join public.profiles w on w.id = s.worker_id
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id, r.business_date);
  end loop;

  for r in
    select distinct
      w.shop_id,
      (p.purchased_at at time zone coalesce(st.timezone, 'Asia/Kolkata'))::date as business_date
    from public.inventory_purchases p
    join public.profiles w on w.id = p.purchased_by
    cross join public.shop_settings st
    where w.shop_id is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id, r.business_date);
  end loop;

  for r in
    select distinct shop_id
    from public.daily_financial_summaries
    where shop_id is not null
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end;
$$;

insert into public.shop_management_schema_version(version)
values (21)
on conflict (version) do nothing;

select pg_notify('pgrst', 'reload schema');
