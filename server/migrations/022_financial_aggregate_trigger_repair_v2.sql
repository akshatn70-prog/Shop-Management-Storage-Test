-- Financial aggregate trigger repair.
-- Uses canonical public.business_date() so the configured dashboard reset time
-- is respected consistently for automatic daily/lifetime summary updates.

create or replace function public.sales_financial_aggregate_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_old text;
  v_shop_new text;
begin
  if old is not null and old.worker_id is not null then
    select shop_id into v_shop_old from public.profiles where id = old.worker_id;
  end if;

  if new is not null and new.worker_id is not null then
    select shop_id into v_shop_new from public.profiles where id = new.worker_id;
  end if;

  if v_shop_old is not null and old.sold_at is not null then
    perform public.refresh_daily_financial_summary(v_shop_old, public.business_date(old.sold_at));
  end if;

  if v_shop_new is not null and new.sold_at is not null then
    perform public.refresh_daily_financial_summary(v_shop_new, public.business_date(new.sold_at));
  end if;

  if v_shop_old is not null then
    perform public.refresh_lifetime_financial_summary(v_shop_old);
  end if;

  if v_shop_new is not null and v_shop_new is distinct from v_shop_old then
    perform public.refresh_lifetime_financial_summary(v_shop_new);
  end if;

  return coalesce(new, old);
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
  v_shop_old text;
  v_shop_new text;
begin
  if old is not null and old.purchased_by is not null then
    select shop_id into v_shop_old from public.profiles where id = old.purchased_by;
  end if;

  if new is not null and new.purchased_by is not null then
    select shop_id into v_shop_new from public.profiles where id = new.purchased_by;
  end if;

  if v_shop_old is not null and old.purchased_at is not null then
    perform public.refresh_daily_financial_summary(v_shop_old, public.business_date(old.purchased_at));
  end if;

  if v_shop_new is not null and new.purchased_at is not null then
    perform public.refresh_daily_financial_summary(v_shop_new, public.business_date(new.purchased_at));
  end if;

  if v_shop_old is not null then
    perform public.refresh_lifetime_financial_summary(v_shop_old);
  end if;

  if v_shop_new is not null and v_shop_new is distinct from v_shop_old then
    perform public.refresh_lifetime_financial_summary(v_shop_new);
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists purchase_financial_aggregate_trigger on public.inventory_purchases;
create trigger purchase_financial_aggregate_trigger
after insert or update or delete on public.inventory_purchases
for each row execute function public.purchase_financial_aggregate_trigger();

do $$
declare r record;
begin
  for r in
    select distinct p.shop_id, public.business_date(s.sold_at) as business_date
    from public.sales s join public.profiles p on p.id=s.worker_id
    where p.shop_id is not null and s.sold_at is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in
    select distinct p.shop_id, public.business_date(i.purchased_at) as business_date
    from public.inventory_purchases i join public.profiles p on p.id=i.purchased_by
    where p.shop_id is not null and i.purchased_at is not null
  loop
    perform public.refresh_daily_financial_summary(r.shop_id,r.business_date);
  end loop;

  for r in select distinct shop_id from public.daily_financial_summaries where shop_id is not null
  loop
    perform public.refresh_lifetime_financial_summary(r.shop_id);
  end loop;
end;
$$;

insert into public.shop_management_schema_version(version)
values (22)
on conflict (version) do nothing;

select pg_notify('pgrst','reload schema');