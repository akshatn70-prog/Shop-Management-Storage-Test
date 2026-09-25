-- Shop Management: email verification + automatic owner activation
-- Run this on an EXISTING Supabase project.
-- The first signup becomes the owner and is activated automatically after email confirmation.
-- Later signups are workers and remain inactive until owner approval.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles(id, full_name, email, role, is_active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.email, ''),
    'worker',
    false
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

alter table public.profiles enable row level security;

drop policy if exists "profiles self or owner" on public.profiles;

create policy "profiles self or owner"
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or (
    (select public.is_active_user())
    and (select public.is_owner())
  )
);

drop policy if exists "owner update profiles" on public.profiles;

create policy "owner update profiles"
on public.profiles
for update
to authenticated
using ((select public.is_owner()))
with check ((select public.is_owner()));

grant select, update on public.profiles to authenticated;

-- Automatically activate the owner when Supabase confirms the signup email.
create or replace function public.handle_user_email_verified()
returns trigger
language plpgsql
security definer
set search_path = ''
as $
begin
  if new.email_confirmed_at is not null
     and old.email_confirmed_at is null then
    update public.profiles
    set is_active=true, updated_at=now()
    where id=new.id and role='owner'::public.user_role;
  end if;
  return new;
end;
$;

drop trigger if exists on_auth_user_email_verified on auth.users;
create trigger on_auth_user_email_verified
after update of email_confirmed_at on auth.users
for each row
execute function public.handle_user_email_verified();

revoke execute on function public.handle_user_email_verified() from public, anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table public.profiles;
exception
  when duplicate_object then null;
  when undefined_object then null;
end
$$;

select pg_notify('pgrst', 'reload schema');
