-- Version 5: fix sale-return credit adjustments.
--
-- Sale returns using "Credit / balance adjustment" are recorded in
-- credit_ledger as:
--   type = 'payment_received'
--   payment_mode = 'credit'
--   cash_amount = 0
--   upi_amount = 0
--
-- The previous constraint allowed only cash/upi/split for payment_received,
-- which caused:
--   credit_ledger_payment_check
-- when recording a sale return against a customer's outstanding balance.
--
-- Keep the constraint strict for normal creditor payments, but explicitly
-- allow the internal credit-adjustment entry used by record_sale_return().

alter table public.credit_ledger
  drop constraint if exists credit_ledger_payment_check;

alter table public.credit_ledger
  add constraint credit_ledger_payment_check
  check (
    (type='credit_sale'
      and payment_mode in ('credit','credit_split')
      and cash_amount=0
      and upi_amount=0)
    or
    (type='payment_received'
      and payment_mode in ('cash','upi','split')
      and cash_amount >= 0
      and upi_amount >= 0
      and abs((cash_amount + upi_amount) - amount) <= 0.01)
    or
    (type='payment_received'
      and payment_mode='credit'
      and cash_amount=0
      and upi_amount=0)
    or
    (type='adjustment')
  );

create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.shop_management_schema_version(version)
values(5)
on conflict(version) do nothing;
