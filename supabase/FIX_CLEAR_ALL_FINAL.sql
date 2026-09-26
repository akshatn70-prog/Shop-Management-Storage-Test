-- FINAL FIX: Clear All Transaction Data
-- This intentionally uses TRUNCATE, not DELETE.
-- It cannot trigger the "DELETE requires a WHERE clause" safe-update error.
-- Run this ONE block in Supabase SQL Editor.

drop function if exists public.clear_all_shop_data();

create function public.clear_all_shop_data()
returns void
language plpgsql
security definer
set search_path = ''
as $clear_all$
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  truncate table
    public.debtor_ledger,
    public.credit_ledger,
    public.sale_transactions,
    public.sales,
    public.inventory_purchases,
    public.daily_closings,
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.automatic_day_end_snapshots,
    public.daily_financial_summaries,
    public.lifetime_financial_summaries,
    public.creditor_daily_financial_aggregates,
    public.returns,
    public.audit_logs
    restart identity;

  perform set_config('shop.allow_stock_change','on',true);

  update public.products
  set current_stock_base = 0,
      updated_at = now()
  where id is not null;

  perform set_config('shop.allow_stock_change','off',true);

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    details
  )
  values(
    auth.uid(),
    'shop_data_cleared',
    'shop',
    jsonb_build_object('cleared_at',now())
  );
end;
$clear_all$;

revoke all on function public.clear_all_shop_data()
from public, anon;

grant execute on function public.clear_all_shop_data()
to authenticated;

select pg_notify('pgrst','reload schema');
