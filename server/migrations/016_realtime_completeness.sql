-- Realtime completeness for the Shop Management UI.
-- Transaction functions are unchanged; this only enables/repairs live delivery.
do $$
declare
  t text;
begin
  foreach t in array array[
    'sales','sale_transactions','inventory_purchases','returns',
    'credit_ledger','debtor_ledger','creditors','debtors',
    'products','profiles','audit_logs','shop_settings',
    'daily_financial_summaries','lifetime_financial_summaries'
  ] loop
    if to_regclass('public.'||t) is not null
       and not exists (
         select 1
         from pg_publication_tables
         where pubname='supabase_realtime'
           and schemaname='public'
           and tablename=t
       )
    then
      execute format('alter publication supabase_realtime add table public.%I',t);
    end if;
  end loop;
end $$;
