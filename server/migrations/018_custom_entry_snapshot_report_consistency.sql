-- 018 custom-entry snapshot + report consistency repair
-- Guarantees product-name snapshots for new rows and repairs recoverable old rows.
-- Does not change transaction calculations or transaction routing.

create or replace function public.fill_product_name_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if coalesce(nullif(btrim(new.product_name_snapshot),''),'Deleted product') = 'Deleted product'
     and new.product_id is not null then
    select p.name into v_name
    from public.products p
    where p.id = new.product_id;

    if v_name is not null and btrim(v_name) <> '' then
      new.product_name_snapshot := v_name;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.fill_product_name_snapshot() from public,anon,authenticated;

drop trigger if exists aaa_fill_product_name_snapshot on public.sales;
create trigger aaa_fill_product_name_snapshot
before insert on public.sales
for each row execute function public.fill_product_name_snapshot();

drop trigger if exists aaa_fill_product_name_snapshot on public.inventory_purchases;
create trigger aaa_fill_product_name_snapshot
before insert on public.inventory_purchases
for each row execute function public.fill_product_name_snapshot();

drop trigger if exists aaa_fill_product_name_snapshot on public.returns;
create trigger aaa_fill_product_name_snapshot
before insert on public.returns
for each row execute function public.fill_product_name_snapshot();

update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id and s.product_name_snapshot='Deleted product';

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id and i.product_name_snapshot='Deleted product';

update public.returns r
set product_name_snapshot=p.name
from public.products p
where r.product_id=p.id and r.product_name_snapshot='Deleted product';

select pg_notify('pgrst','reload schema');
