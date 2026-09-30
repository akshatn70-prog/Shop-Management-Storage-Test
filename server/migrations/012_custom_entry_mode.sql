-- Custom Entry adds an owner-only historical-entry path. It reuses the
-- existing protected transaction RPCs and changes only their business dates
-- inside the current database transaction.

alter table public.sales
  add column if not exists custom_entry boolean not null default false;
alter table public.sale_transactions
  add column if not exists custom_entry boolean not null default false;
alter table public.inventory_purchases
  add column if not exists custom_entry boolean not null default false;
alter table public.returns
  add column if not exists custom_entry boolean not null default false;
alter table public.credit_ledger
  add column if not exists custom_entry boolean not null default false;
alter table public.debtor_ledger
  add column if not exists custom_entry boolean not null default false;

create or replace function public.apply_custom_entry_timestamp()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_date date;
  v_timezone text;
  v_reset time;
  v_local_timestamp timestamp;
  v_timestamp timestamptz;
  v_date_column text;
begin
  if coalesce(current_setting('shop.custom_entry_business_date', true), '') = '' then
    return new;
  end if;

  v_date := current_setting('shop.custom_entry_business_date', true)::date;
  select coalesce(s.timezone, 'Asia/Kolkata'),
         coalesce(s.dashboard_reset_time, '00:00')::time
    into v_timezone, v_reset
  from public.shop_settings s
  where s.id = 1;

  -- Pick a local time that belongs to the requested business date even when
  -- the shop has a non-midnight dashboard reset time.
  v_local_timestamp := v_date::timestamp
    + greatest(interval '12 hours', v_reset - time '00:00' + interval '1 minute');
  v_timestamp := v_local_timestamp at time zone v_timezone;

  v_date_column := case tg_table_name
    when 'sales' then 'sold_at'
    when 'sale_transactions' then 'created_at'
    when 'inventory_purchases' then 'purchased_at'
    when 'returns' then 'returned_at'
    else 'created_at'
  end;
  new := jsonb_populate_record(
    new,
    jsonb_build_object(v_date_column, v_timestamp, 'custom_entry', true)
  );
  return new;
end;
$$;

drop trigger if exists custom_entry_timestamp on public.sales;
create trigger custom_entry_timestamp before insert on public.sales
for each row execute function public.apply_custom_entry_timestamp();
drop trigger if exists custom_entry_timestamp on public.sale_transactions;
create trigger custom_entry_timestamp before insert on public.sale_transactions
for each row execute function public.apply_custom_entry_timestamp();
drop trigger if exists custom_entry_timestamp on public.inventory_purchases;
create trigger custom_entry_timestamp before insert on public.inventory_purchases
for each row execute function public.apply_custom_entry_timestamp();
drop trigger if exists custom_entry_timestamp on public.returns;
create trigger custom_entry_timestamp before insert on public.returns
for each row execute function public.apply_custom_entry_timestamp();
drop trigger if exists custom_entry_timestamp on public.credit_ledger;
create trigger custom_entry_timestamp before insert on public.credit_ledger
for each row execute function public.apply_custom_entry_timestamp();
drop trigger if exists custom_entry_timestamp on public.debtor_ledger;
create trigger custom_entry_timestamp before insert on public.debtor_ledger
for each row execute function public.apply_custom_entry_timestamp();

create or replace function public.record_custom_entry(
  p_kind text,
  p_business_date date,
  p_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if not (select public.is_active_user()) then
    raise exception 'Account is inactive';
  end if;
  if not (select public.is_owner()) then
    raise exception 'Owner access is required for Custom Entry';
  end if;
  if p_business_date is null or p_business_date > public.business_date(now()) then
    raise exception 'Choose today or an earlier business date';
  end if;
  if jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Transaction details are missing';
  end if;

  perform set_config('shop.custom_entry_business_date', p_business_date::text, true);

  case p_kind
    when 'record_sale' then
      v_result := to_jsonb(public.record_sale(
        (p_payload->>'p_product_id')::uuid,
        (p_payload->>'p_worker_id')::uuid,
        (p_payload->>'p_quantity_base')::numeric,
        (p_payload->>'p_quantity_display')::numeric,
        p_payload->>'p_sold_unit',
        (p_payload->>'p_selling_price_per_base_unit')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        nullif(p_payload->>'p_cash_amount', '')::numeric,
        nullif(p_payload->>'p_upi_amount', '')::numeric
      ));
    when 'complete_cart_sale' then
      v_result := public.complete_cart_sale(
        (p_payload->>'p_worker_id')::uuid,
        p_payload->'p_items',
        p_payload->>'p_payment_mode',
        coalesce(nullif(p_payload->>'p_cash_amount', '')::numeric, 0),
        coalesce(nullif(p_payload->>'p_upi_amount', '')::numeric, 0),
        coalesce(nullif(p_payload->>'p_credit_amount', '')::numeric, 0),
        nullif(p_payload->>'p_creditor_id', '')::uuid
      );
    when 'add_inventory_purchase' then
      v_result := to_jsonb(public.add_inventory_purchase(
        (p_payload->>'p_product_id')::uuid,
        (p_payload->>'p_quantity_base')::numeric,
        (p_payload->>'p_quantity_display')::numeric,
        p_payload->>'p_purchase_unit',
        (p_payload->>'p_purchase_price')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        coalesce(nullif(p_payload->>'p_cash_amount', '')::numeric, 0),
        coalesce(nullif(p_payload->>'p_upi_amount', '')::numeric, 0),
        coalesce(nullif(p_payload->>'p_credit_amount', '')::numeric, 0),
        nullif(p_payload->>'p_debtor_id', '')::uuid,
        coalesce(nullif(p_payload->>'p_pre_stock', '')::boolean, false),
        p_payload->>'p_supplier_name',
        nullif(p_payload->>'p_selling_price', '')::numeric
      ));
    when 'record_sale_return' then
      v_result := to_jsonb(public.record_sale_return(
        (p_payload->>'p_product_id')::uuid,
        (p_payload->>'p_quantity_base')::numeric,
        (p_payload->>'p_quantity_display')::numeric,
        p_payload->>'p_return_unit',
        (p_payload->>'p_return_price_per_base_unit')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        nullif(p_payload->>'p_source_id', '')::uuid,
        coalesce(p_payload->>'p_reason', ''),
        nullif(p_payload->>'p_account_id', '')::uuid
      ));
    when 'record_purchase_return' then
      v_result := to_jsonb(public.record_purchase_return(
        (p_payload->>'p_product_id')::uuid,
        (p_payload->>'p_quantity_base')::numeric,
        (p_payload->>'p_quantity_display')::numeric,
        p_payload->>'p_return_unit',
        (p_payload->>'p_return_price_per_base_unit')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        nullif(p_payload->>'p_source_id', '')::uuid,
        coalesce(p_payload->>'p_reason', ''),
        nullif(p_payload->>'p_account_id', '')::uuid
      ));
    when 'receive_credit_payment' then
      v_result := public.receive_credit_payment(
        (p_payload->>'p_creditor_id')::uuid,
        (p_payload->>'p_amount')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        coalesce(nullif(p_payload->>'p_cash_amount', '')::numeric, 0),
        coalesce(nullif(p_payload->>'p_upi_amount', '')::numeric, 0)
      );
    when 'pay_debtor' then
      v_result := to_jsonb(public.pay_debtor(
        (p_payload->>'p_debtor_id')::uuid,
        (p_payload->>'p_amount')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash'),
        nullif(p_payload->>'p_cash_amount', '')::numeric,
        nullif(p_payload->>'p_upi_amount', '')::numeric
      ));
    when 'pay_purchase_credit' then
      v_result := to_jsonb(public.pay_purchase_credit(
        (p_payload->>'p_purchase_id')::uuid,
        (p_payload->>'p_amount')::numeric,
        coalesce(p_payload->>'p_payment_mode', 'cash')
      ));
    else
      raise exception 'This transaction type is not supported in Custom Entry';
  end case;

  return jsonb_build_object('kind', p_kind, 'result', v_result, 'business_date', p_business_date);
end;
$$;

revoke all on function public.apply_custom_entry_timestamp() from public, anon, authenticated;
revoke all on function public.record_custom_entry(text,date,jsonb) from public, anon;
grant execute on function public.record_custom_entry(text,date,jsonb) to authenticated;

-- Preserve custom transaction detail from automatic cleanup. Clear All remains
-- owner-only and uses TRUNCATE, so this row-level guard does not affect it.
create or replace function public.prevent_custom_entry_detail_delete()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.custom_entry then
    return null;
  end if;
  return old;
end;
$$;
revoke all on function public.prevent_custom_entry_detail_delete() from public, anon, authenticated;

drop trigger if exists preserve_custom_entry_sales on public.sales;
create trigger preserve_custom_entry_sales before delete on public.sales
for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_purchases on public.inventory_purchases;
create trigger preserve_custom_entry_purchases before delete on public.inventory_purchases
for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_credit_ledger on public.credit_ledger;
create trigger preserve_custom_entry_credit_ledger before delete on public.credit_ledger
for each row execute function public.prevent_custom_entry_detail_delete();

select pg_notify('pgrst', 'reload schema');
create table if not exists public.shop_management_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);
insert into public.shop_management_schema_version(version)
values (12)
on conflict (version) do nothing;
