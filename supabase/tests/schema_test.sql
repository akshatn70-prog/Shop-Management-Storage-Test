begin;

create extension if not exists pgtap with schema extensions;
set search_path = extensions, public;

select plan(25);

select has_table('public','profiles','profiles table exists');
select has_table('public','products','products table exists');
select has_table('public','inventory_purchases','purchases table exists');
select has_table('public','sales','sales table exists');
select has_table('public','daily_closings','daily closings table exists');
select has_table('public','day_end_summaries','day-end summaries table exists');
select has_table('public','day_end_summary_lines','day-end summary lines table exists');
select has_table('public','shop_settings','settings table exists');
select has_table('public','audit_logs','audit log table exists');

select ok((select relrowsecurity from pg_class where oid='public.profiles'::regclass),'profiles RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.products'::regclass),'products RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.sales'::regclass),'sales RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.daily_closings'::regclass),'closing RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.day_end_summaries'::regclass),'day-end RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.shop_settings'::regclass),'settings RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.audit_logs'::regclass),'audit RLS enabled');

select function_returns('public.record_sale','public.sales','record_sale returns sales');
select function_returns('public.create_product','uuid','create_product returns uuid');
select function_returns('public.approve_closing','void','approve_closing returns void');
select function_returns('public.submit_daily_closing','uuid','submit_daily_closing returns uuid');
select function_returns('public.submit_day_end_summary','void','submit_day_end_summary returns void');
select function_returns('public.confirm_day_end_summary','void','confirm_day_end_summary returns void');
select function_returns('public.clear_all_shop_data','void','clear_all_shop_data returns void');

select has_trigger('public','profiles','protect_last_owner','last active owner is protected');
select has_trigger('public','products','protect_product_stock_direct_update','direct stock changes are protected');

select * from finish();
rollback;
