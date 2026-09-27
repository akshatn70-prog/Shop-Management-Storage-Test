-- Version 2: preserve product history and add owner product editing.

-- Recover placeholder snapshots while the product row still exists.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and (btrim(coalesce(s.product_name_snapshot,''))='' or s.product_name_snapshot='Deleted product');

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and (btrim(coalesce(i.product_name_snapshot,''))='' or i.product_name_snapshot='Deleted product');

-- Owner-only product editor.
create or replace function public.update_product(
  p_product_id uuid,
  p_name text,
  p_purchase_price numeric,
  p_selling_price numeric,
  p_low_stock_threshold_base numeric
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.products;
  v_name text:=btrim(coalesce(p_name,''));
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if v_name='' or p_purchase_price<0 or p_selling_price<0 or p_low_stock_threshold_base<0 then
    raise exception 'Invalid product details';
  end if;

  select * into p
  from public.products
  where id=p_product_id and is_active=true
  for update;

  if not found then raise exception 'Product not found or inactive'; end if;

  if exists(
    select 1 from public.products
    where is_active=true
      and id<>p_product_id
      and lower(btrim(name))=lower(v_name)
  ) then
    raise exception 'An active product with this name already exists';
  end if;

  update public.products
  set name=v_name,
      purchase_price_per_base_unit=round(p_purchase_price,2),
      selling_price_per_base_unit=round(p_selling_price,2),
      low_stock_threshold_base=p_low_stock_threshold_base,
      updated_at=now()
  where id=p_product_id;

  perform public.write_audit(
    'product_updated',
    'product',
    p_product_id,
    jsonb_build_object(
      'old_name',p.name,
      'new_name',v_name,
      'old_purchase_price',p.purchase_price_per_base_unit,
      'new_purchase_price',round(p_purchase_price,2),
      'old_selling_price',p.selling_price_per_base_unit,
      'new_selling_price',round(p_selling_price,2),
      'low_stock_threshold_base',p_low_stock_threshold_base
    )
  );
end;
$$;

revoke all on function public.update_product(uuid,text,numeric,numeric,numeric) from public,anon;
grant execute on function public.update_product(uuid,text,numeric,numeric,numeric) to authenticated;

-- Deletion is now a non-destructive archive. Historical sales/purchases keep
-- their product snapshots and the archived product no longer appears in Stock.
create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.products;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  select * into p
  from public.products
  where id=p_product_id and is_active=true
  for update;

  if not found then raise exception 'Product not found or already deleted'; end if;

  update public.products
  set is_active=false,
      updated_at=now()
  where id=p_product_id;

  perform public.write_audit(
    'product_archived',
    'product',
    p_product_id,
    jsonb_build_object(
      'name',p.name,
      'purchase_price',p.purchase_price_per_base_unit,
      'selling_price',p.selling_price_per_base_unit
    )
  );
end;
$$;

revoke all on function public.delete_product(uuid) from public,anon;
grant execute on function public.delete_product(uuid) to authenticated;

-- Archived names can be reused by a new active product.
alter table public.products drop constraint if exists products_name_key;
create unique index if not exists products_active_name_uidx
on public.products(lower(btrim(name)))
where is_active=true;

-- Mark the migration as installed in the customer database.
create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(2)
on conflict(version) do nothing;
