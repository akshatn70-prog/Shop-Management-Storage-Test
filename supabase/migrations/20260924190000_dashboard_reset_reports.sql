-- Dashboard reset time and business-day reporting support.
-- Existing installations: apply this migration after the current schema/migrations.

alter table public.shop_settings
  add column if not exists dashboard_reset_time text not null default '00:00';

do $$
begin
  alter table public.shop_settings
    add constraint shop_settings_dashboard_reset_time_check
    check (dashboard_reset_time ~ '^[0-2][0-9]:[0-5][0-9]$' and dashboard_reset_time < '24:00');
exception when duplicate_object then null;
end $$;

update public.shop_settings
set dashboard_reset_time='00:00'
where dashboard_reset_time is null or dashboard_reset_time !~ '^[0-2][0-9]:[0-5][0-9]$' or dashboard_reset_time >= '24:00';

comment on column public.shop_settings.dashboard_reset_time is
  'Local shop time at which the current business-day dashboard period resets; reports retain prior business days.';
