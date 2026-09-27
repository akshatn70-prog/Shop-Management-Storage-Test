-- Version 4: automatic storage-retention scheduler.
-- This is intentionally separate from product deletion.
--
-- Retention rules are implemented by the existing
-- public.run_storage_retention_cleanup() function:
--   sales                 -> 90 days
--   sale_transactions     -> 90 days when no longer referenced
--   inventory purchases   -> 1 year, excluding pre-stock and unpaid credit
--   audit logs             -> 30 days
--   settled credit ledger -> 7 days after settlement
-- Permanent summaries and product rows are not deleted by this job.
--
-- The scheduled time is 01:00 Asia/Kolkata.
-- Supabase databases normally run on UTC, so 01:00 IST = 19:30 UTC.

create extension if not exists pg_cron;

-- Make this migration idempotent if the job already exists.
select cron.unschedule(jobid)
from cron.job
where jobname='shop-management-storage-retention';

select cron.schedule(
  'shop-management-storage-retention',
  '30 19 * * *',
  $$select public.run_storage_retention_cleanup();$$
);

create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(4)
on conflict(version) do nothing;
