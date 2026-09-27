-- Version 3: product delete is a true permanent delete.
-- Product deletion is intentionally separate from storage-retention cleanup.
--
-- Historical rows keep their product_name_snapshot and product_id becomes NULL
-- because inventory_purchases, sales, and returns reference products with
-- ON DELETE SET NULL.

create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.products;
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  select *
    into p
  from public.products
  where id=p_product_id
  for update;

  if not found then
    raise exception 'Product not found or already deleted';
  end if;

  -- Permanent deletion. This is NOT part of automatic retention.
  -- Product-history foreign keys use ON DELETE SET NULL, while snapshots
  -- preserve the historical product name in sales/purchases/returns.
  delete from public.products
  where id=p_product_id;
end;
$$;

revoke all on function public.delete_product(uuid) from public,anon;
grant execute on function public.delete_product(uuid) to authenticated;

-- V2 removed the old global name constraint and replaced it with an
-- active-product-only unique index. Keep that behavior so a deleted/legacy
-- inactive product never blocks a newly created product with the same name.
alter table public.products
  drop constraint if exists products_name_key;

create unique index if not exists products_active_name_uidx
on public.products(lower(btrim(name)))
where is_active=true;

create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(3)
on conflict(version) do nothing;
