-- EMERGENCY FIX: Clear All Transaction Data
-- Run this block ONCE in Supabase SQL Editor.
-- This replaces any older clear_all_shop_data() implementation
-- that contains DELETE statements without WHERE clauses.

drop function if exists public.clear_all_shop_data();

create or replace function public.clear_all_shop_data()
returns void
language plpgsql
security definer
set search_path = ''
as $clear_all$
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  -- One Supabase project represents one shop.
  -- Explicit WHERE clauses are required by the database safety rule.
  delete from public.debtor_ledger where true;
  delete from public.credit_ledger where true;
  delete from public.sale_transactions where true;
  delete from public.sales where true;
  delete from public.inventory_purchases where true;
  delete from public.daily_closings where true;
  delete from public.day_end_summary_lines where true;
  delete from public.day_end_summaries where true;
  delete from public.automatic_day_end_snapshots where true;
  delete from public.daily_financial_summaries where true;
  delete from public.lifetime_financial_summaries where true;
  delete from public.creditor_daily_financial_aggregates where true;
  delete from public.audit_logs where true;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base = 0,
      updated_at = now()
  where id is not null;

  perform set_config('shop.allow_stock_change','off',true);

  -- Keep a permanent marker that the owner cleared the shop data.
  insert into public.audit_logs(actor_id,action,entity_type,details)
  values(
    (select auth.uid()),
    'shop_data_cleared',
    'shop',
    jsonb_build_object('cleared_at',now())
  );
end;
$clear_all$;

revoke all on function public.clear_all_shop_data() from public,anon;
grant execute on function public.clear_all_shop_data() to authenticated;

select pg_notify('pgrst','reload schema');
