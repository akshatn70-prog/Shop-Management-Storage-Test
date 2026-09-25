-- Permanent product deletion.
-- Historical sales, purchases and legacy day-end lines keep a product-name snapshot.
-- Their product_id becomes NULL when the product row is deleted, so history is preserved.
-- A later product with the same name is a completely new product.

alter table public.sales
  add column if not exists product_name_snapshot text not null default 'Deleted product';

alter table public.inventory_purchases
  add column if not exists product_name_snapshot text not null default 'Deleted product';

alter table public.day_end_summary_lines
  add column if not exists product_name_snapshot text not null default 'Deleted product';

update public.sales s
set product_name_snapshot = p.name
from public.products p
where s.product_id = p.id
  and (s.product_name_snapshot = 'Deleted product' or s.product_name_snapshot is null);

update public.inventory_purchases i
set product_name_snapshot = p.name
from public.products p
where i.product_id = p.id
  and (i.product_name_snapshot = 'Deleted product' or i.product_name_snapshot is null);

update public.day_end_summary_lines l
set product_name_snapshot = p.name
from public.products p
where l.product_id = p.id
  and (l.product_name_snapshot = 'Deleted product' or l.product_name_snapshot is null);

alter table public.sales alter column product_id drop not null;
alter table public.inventory_purchases alter column product_id drop not null;
alter table public.day_end_summary_lines alter column product_id drop not null;

do $$
declare r record;
begin
  for r in
    select n.nspname as schema_name,
           c.relname as table_name,
           con.conname as constraint_name
    from pg_constraint con
    join pg_class c on c.oid=con.conrelid
    join pg_namespace n on n.oid=c.relnamespace
    join pg_class ref on ref.oid=con.confrelid
    join pg_namespace rn on rn.oid=ref.relnamespace
    where con.contype='f'
      and n.nspname='public'
      and rn.nspname='public'
      and ref.relname='products'
      and c.relname in ('sales','inventory_purchases','day_end_summary_lines')
  loop
    execute format('alter table %I.%I drop constraint %I',
      r.schema_name,r.table_name,r.constraint_name);
  end loop;
end $$;

alter table public.sales
  add constraint sales_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

alter table public.inventory_purchases
  add constraint inventory_purchases_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

alter table public.day_end_summary_lines
  add constraint day_end_summary_lines_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

-- Remove old soft-deleted product rows now that their historical references are safe.
delete from public.products where is_active=false;

create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.products;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  select * into p
  from public.products
  where id=p_product_id
  for update;

  if not found then raise exception 'Product not found'; end if;

  delete from public.products
  where id=p_product_id;
end;
$$;

revoke execute on function public.delete_product(uuid) from public, anon;
grant execute on function public.delete_product(uuid) to authenticated;

-- Product deletion is available only through the protected owner RPC.
revoke delete on public.products from authenticated;
