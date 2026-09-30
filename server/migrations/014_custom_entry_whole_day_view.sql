-- Custom Entry historical whole-app viewing context.
-- This migration is READ-ONLY with respect to transaction behavior.
-- It supplies the frontend with the rows belonging to one business date,
-- while physical stock and all transaction RPCs remain unchanged.

create or replace function public.get_business_day_view(p_business_date date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with me as (
    select p.shop_id
    from public.profiles p
    where p.id = (select auth.uid())
      and p.is_active = true
    limit 1
  ),
  sales_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(s) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', wp.full_name)
          from public.profiles wp
          where wp.id = s.worker_id
        ), '{}'::jsonb),
        'products', coalesce((
          select jsonb_build_object('name', pr.name)
          from public.products pr
          where pr.id = s.product_id
        ), '{}'::jsonb)
      )
      order by s.sold_at desc
    ), '[]'::jsonb) as value
    from public.sales s
    join public.profiles sp on sp.id = s.worker_id
    where sp.shop_id = (select shop_id from me)
      and public.business_date(s.sold_at) = p_business_date
  ),
  purchase_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(i) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', pp.full_name)
          from public.profiles pp
          where pp.id = i.purchased_by
        ), '{}'::jsonb)
      )
      order by i.purchased_at desc
    ), '[]'::jsonb) as value
    from public.inventory_purchases i
    join public.profiles ip on ip.id = i.purchased_by
    where ip.shop_id = (select shop_id from me)
      and public.business_date(i.purchased_at) = p_business_date
  ),
  credit_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(l) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', lp.full_name)
          from public.profiles lp
          where lp.id = l.worker_id
        ), '{}'::jsonb)
      )
      order by l.created_at desc
    ), '[]'::jsonb) as value
    from public.credit_ledger l
    where l.shop_id = (select shop_id from me)
      and public.business_date(l.created_at) = p_business_date
  ),
  debtor_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(l) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', lp.full_name)
          from public.profiles lp
          where lp.id = l.worker_id
        ), '{}'::jsonb)
      )
      order by l.created_at desc
    ), '[]'::jsonb) as value
    from public.debtor_ledger l
    where l.shop_id = (select shop_id from me)
      and public.business_date(l.created_at) = p_business_date
  ),
  return_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(r) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', rp.full_name)
          from public.profiles rp
          where rp.id = r.returned_by
        ), '{}'::jsonb),
        'products', coalesce((
          select jsonb_build_object('name', pr.name)
          from public.products pr
          where pr.id = r.product_id
        ), '{}'::jsonb)
      )
      order by r.returned_at desc
    ), '[]'::jsonb) as value
    from public.returns r
    where r.shop_id = (select shop_id from me)
      and public.business_date(r.returned_at) = p_business_date
  ),
  audit_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(a) ||
      jsonb_build_object(
        'profiles', coalesce((
          select jsonb_build_object('full_name', ap.full_name)
          from public.profiles ap
          where ap.id = a.actor_id
        ), '{}'::jsonb)
      )
      order by a.created_at desc
    ), '[]'::jsonb) as value
    from public.audit_logs a
    join public.profiles ap2 on ap2.id = a.actor_id
    where ap2.shop_id = (select shop_id from me)
      and public.business_date(a.created_at) = p_business_date
  ),
  summary_row as (
    select coalesce(to_jsonb(d), '{}'::jsonb) as value
    from public.daily_financial_summaries d
    where d.business_date = p_business_date
    limit 1
  )
  select jsonb_build_object(
    'business_date', p_business_date,
    'sales', (select value from sales_rows),
    'purchases', (select value from purchase_rows),
    'credit_ledger', (select value from credit_rows),
    'debtor_ledger', (select value from debtor_rows),
    'returns', (select value from return_rows),
    'audit', (select value from audit_rows),
    'summary', coalesce((select value from summary_row), '{}'::jsonb)
  );
$$;

revoke execute on function public.get_business_day_view(date) from public, anon;
grant execute on function public.get_business_day_view(date) to authenticated;
