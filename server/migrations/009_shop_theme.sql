-- Version 9: shop theme setting.
-- Adds the three supported UI themes without changing existing behavior.
alter table public.shop_settings
  add column if not exists theme text not null default 'current';

alter table public.shop_settings
  drop constraint if exists shop_settings_theme_check;

alter table public.shop_settings
  add constraint shop_settings_theme_check
  check (theme in ('current','light-pink','pink'));

update public.shop_settings
set theme='current'
where theme is null or theme not in ('current','light-pink','pink');
