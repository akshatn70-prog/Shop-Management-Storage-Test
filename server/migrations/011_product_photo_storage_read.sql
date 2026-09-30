-- Product photo Storage read policy required by Clear All's Storage API cleanup.
drop policy if exists "product photos read active users" on storage.objects;
create policy "product photos read active users"
on storage.objects for select to authenticated
using (bucket_id='product-photos' and (select public.is_active_user()));
