-- Shop ID support: workers identify the shop, while owner approval remains in the existing flow.
alter table public.shop_settings
  add column if not exists shop_id text;

update public.shop_settings
set shop_id = 'SHOP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
where id = 1 and (shop_id is null or btrim(shop_id) = '');

alter table public.shop_settings
  alter column shop_id set not null;

create unique index if not exists shop_settings_shop_id_uidx
  on public.shop_settings(shop_id);

alter table public.profiles
  add column if not exists shop_id text;

update public.profiles
set shop_id = (select shop_id from public.shop_settings where id = 1)
where shop_id is null;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shop_id text;
begin
  select s.shop_id into v_shop_id from public.shop_settings s where s.id = 1;
  insert into public.profiles (id, full_name, email, role, is_active, shop_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.email, ''),
    'worker',
    false,
    v_shop_id
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

grant execute on function public.handle_new_user() to postgres;
