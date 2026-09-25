# Supabase migration history

The repository has two installation paths:

- Fresh database: run supabase/schema.sql. It contains the current canonical schema and is the safest starting point for a new project.
- Existing database: apply migrations in timestamp order. Do not replace an existing production database by rerunning the canonical schema.

## Why the early sales migrations overlap

20260924_sales_improvements.sql was the first compatibility migration for payment-aware sales.
20260924123000_sales_split_reset.sql is a follow-up compatibility migration that safely re-applies the same payment structure and replaces the reset/sales functions. It is intentionally retained so an installation that stopped after the first migration can be upgraded without manually reconstructing database state.
20260924150000_day_end_payments.sql upgrades legacy day-end records and payment-aware closing functions.
20260924170000_audit_safety_fixes.sql hardens the existing installation: generated-column-safe closing logic, protected stock/purchase operations, owner protection, automatic day-end snapshots, payment/business-rule settings and reset/audit behavior.

20260924170000 should be applied after the earlier migrations. The migrations are written to be repeat-safe where practical; do not delete an already-applied migration from an existing deployment.

## Current workflow

The active frontend workflow remains unchanged:

Purchase/Stock Entry → Current Stock → Worker Sales → Automatic Stock Reduction → Revenue & Profit → Automatic Cash/UPI Summary → Reconciliation → History

The old worker-entered day-end/owner-confirmation functions remain in the database for compatibility with legacy records, but the current UI does not use them.
