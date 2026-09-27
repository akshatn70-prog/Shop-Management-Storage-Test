-- Version 6: client-side transaction/report fixes.
--
-- v6 does not change business tables or existing financial aggregates.
-- The corresponding application release fixes:
--   1) weight-based sale/cart totals (grams are the storage base unit,
--      while selling_price_per_base_unit is the price per kg),
--   2) Reports auto-refresh fallback so fresh aggregates are rendered,
--   3) Reports horizontal scroll position is preserved across refresh/rerender,
--   4) Audit date filtering is wired to the selected date,
--   5) credit_ledger is included in the realtime refresh set.
--
-- Keep a database-side version marker so the existing migration/update
-- mechanism can distribute this release to already-installed shops.

create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(6)
on conflict(version) do nothing;
