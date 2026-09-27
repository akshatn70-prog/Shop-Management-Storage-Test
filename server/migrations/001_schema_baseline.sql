-- Shop Management schema-version marker.
-- Baseline for the schema shipped in public/shop-management-final.sql.
-- This migration is intentionally non-destructive.
create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values (1)
on conflict (version) do nothing;
