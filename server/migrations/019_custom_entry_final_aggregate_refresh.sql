-- 019 custom-entry final aggregate refresh
-- Reuses the existing transaction RPCs unchanged and rebuilds the selected
-- business-date aggregate after the nested transaction has fully completed.

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
  v_shop_id text;
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

  select p.shop_id into v_shop_id
  from public.profiles p
  where p.id=(select auth.uid())
  limit 1;

  if v_shop_id is not null then
    perform public.refresh_daily_financial_summary(v_shop_id,p_business_date);
    perform public.refresh_lifetime_financial_summary(v_shop_id);
  end if;

  return jsonb_build_object('kind',p_kind,'result',v_result,'business_date',p_business_date);
end;
$$;

revoke all on function public.record_custom_entry(text,date,jsonb) from public,anon;
grant execute on function public.record_custom_entry(text,date,jsonb) to authenticated;

select pg_notify('pgrst','reload schema');
