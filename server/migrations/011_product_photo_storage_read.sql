-- Product photo storage. Additive only: no existing transaction or product data is changed.
alter table public.products add column if not exists photo_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos','product-photos',true,5242880,array['image/webp','image/jpeg','image/png']::text[])
on conflict (id) do update
set public=true,file_size_limit=5242880,allowed_mime_types=array['image/webp','image/jpeg','image/png']::text[];

drop policy if exists "product photos upload active users" on storage.objects;
create policy "product photos upload active users" on storage.objects for insert to authenticated
with check (bucket_id='product-photos' and (select public.is_active_user()) and name like 'products/%');

drop policy if exists "product photos update active users" on storage.objects;
create policy "product photos update active users" on storage.objects for update to authenticated
using (bucket_id='product-photos' and (select public.is_active_user()))
with check (bucket_id='product-photos' and (select public.is_active_user()));

drop policy if exists "product photos delete active users" on storage.objects;
create policy "product photos delete active users" on storage.objects for delete to authenticated
using (bucket_id='product-photos' and (select public.is_active_user()));

create or replace function public.set_product_photo(p_product_id uuid,p_photo_path text)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_photo_path is not null and p_photo_path not like 'products/'||p_product_id::text||'/%' then raise exception 'Invalid product photo path'; end if;
  update public.products set photo_path=p_photo_path,updated_at=now() where id=p_product_id and is_active=true;
  if not found then raise exception 'Product not found or inactive'; end if;
end;
$$;
revoke all on function public.set_product_photo(uuid,text) from public,anon;
grant execute on function public.set_product_photo(uuid,text) to authenticated;
select pg_notify('pgrst','reload schema');

-- Clear All uses Storage API emptyBucket(), which requires SELECT permission.
drop policy if exists "product photos read active users" on storage.objects;
create policy "product photos read active users"
on storage.objects for select to authenticated
using (bucket_id='product-photos' and (select public.is_active_user()));
