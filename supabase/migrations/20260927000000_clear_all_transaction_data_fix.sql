-- Fix Clear All so it works across both current and legacy shop databases.
-- It intentionally clears transaction/history data only. Products, settings,
-- profiles and auth accounts are preserved, matching the existing button behavior.

create or replace function public.clear_all_shop_data_v2()
returns void
language plpgsql
security definer
set search_path=''
as $clear_all_v2$
declare
  v_table text;
  v_tables text[] := array[
    'debtor_ledger',
    'credit_ledger',
    'returns',
    'sale_transactions',
    'sales',
    'inventory_purchases',
    'daily_closings',
    'day_end_summary_lines',
    'day_end_summaries',
    'automatic_day_end_snapshots',
    'daily_financial_summaries',
    'lifetime_financial_summaries',
    'creditor_daily_financial_aggregates',
    'audit_logs'
  ];
  v_existing text[] := array[]::text[];
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is not null then
      v_existing := array_append(v_existing, format('public.%I', v_table));
    end if;
  end loop;

  if coalesce(array_length(v_existing, 1), 0) > 0 then
    execute 'truncate table ' || array_to_string(v_existing, ', ') || ' restart identity';
  end if;

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=0,
      updated_at=now()
  where id is not null;
  perform set_config('shop.allow_stock_change','off',true);

  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object(
      'cleared_at',now(),
      'tables_cleared',coalesce(v_existing, array[]::text[])
    )
  );
end;
$clear_all_v2$;

revoke all on function public.clear_all_shop_data_v2() from public,anon;
grant execute on function public.clear_all_shop_data_v2() to authenticated;
