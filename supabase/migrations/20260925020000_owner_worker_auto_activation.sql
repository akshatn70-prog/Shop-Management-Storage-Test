-- Shop Management auth flow:
-- First account in a shop is the owner.
-- Every later account is a worker.
-- Email verification activates the owner.
-- Workers remain inactive until the shop owner approves them.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_has_any_profile boolean;
  v_role public.user_role;
begin
  select s.shop_id
    into v_shop_id
  from public.shop_settings s
  where s.id = 1;

  select exists(select 1 from public.profiles)
    into v_has_any_profile;

  v_role := case
    when v_has_any_profile then 'worker'::public.user_role
    else 'owner'::public.user_role
  end;

  insert into public.profiles(
    id, full_name, email, role, is_active, shop_id
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.email, ''),
    v_role,
    false,
    coalesce(nullif(new.raw_user_meta_data ->> 'shop_id', ''), v_shop_id)
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = case
          when public.profiles.full_name = '' then excluded.full_name
          else public.profiles.full_name
        end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Repair old installations where no owner exists.
-- The oldest existing account becomes the owner.
do $$
begin
  if not exists (
    select 1
    from public.profiles
    where role = 'owner'::public.user_role
  ) then
    update public.profiles
    set role = 'owner'::public.user_role
    where id = (
      select id
      from public.profiles
      order by created_at asc
      limit 1
    );
  end if;
end;
$$;

-- Owner email verification can activate the owner.
-- Worker email verification must NOT activate the worker.
create or replace function public.activate_user_after_email_verification()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_confirmed timestamptz;
  v_role public.user_role;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'Authentication required.');
  end if;

  select u.email_confirmed_at
    into v_confirmed
  from auth.users u
  where u.id = v_uid;

  if v_confirmed is null then
    return jsonb_build_object('ok', false, 'error', 'Email is not verified yet.');
  end if;

  select role
    into v_role
  from public.profiles
  where id = v_uid;

  if v_role is null then
    return jsonb_build_object('ok', false, 'error', 'Account profile not found.');
  end if;

  if v_role <> 'owner'::public.user_role then
    return jsonb_build_object(
      'ok', false,
      'pending_approval', true,
      'role', v_role::text,
      'is_active', false
    );
  end if;

  update public.profiles
  set is_active = true,
      updated_at = now()
  where id = v_uid;

  return jsonb_build_object(
    'ok', true,
    'role', 'owner',
    'is_active', true
  );
end;
$$;

revoke execute on function public.activate_user_after_email_verification() from public, anon;
grant execute on function public.activate_user_after_email_verification() to authenticated;

-- Database-level fallback for email verification:
-- only an owner is automatically activated.
create or replace function public.handle_user_email_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email_confirmed_at is not null
     and old.email_confirmed_at is null then
    update public.profiles p
    set is_active = true,
        updated_at = now()
    where p.id = new.id
      and p.role = 'owner'::public.user_role;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_email_verified on auth.users;
create trigger on_auth_user_email_verified
after update of email_confirmed_at on auth.users
for each row
execute function public.handle_user_email_verified();

revoke execute on function public.handle_user_email_verified() from public, anon, authenticated;

-- Ensure profiles are available through Realtime so a worker can detect
-- owner approval immediately. The app also polls as a fallback.
do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception
  when duplicate_object then null;
  when undefined_object then null;
end;
$$;

select pg_notify('pgrst', 'reload schema');
