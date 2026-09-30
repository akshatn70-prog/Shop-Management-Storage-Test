-- Custom Entry integrity fixes.
-- Ordinary transaction calls are unchanged. The date-aware branches below
-- only run while record_custom_entry has set its transaction-local context.

-- Keep the chosen business date while retaining transaction entry order within
-- that day. This lets a same-day restock entered first supply the cost basis
-- for a later historical sale. Normal transaction timestamps are untouched.
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
  v_now_local timestamp;
  v_local_timestamp timestamp;
  v_timestamp timestamptz;
  v_date_column text;
begin
  if coalesce(current_setting('shop.custom_entry_business_date',true),'')='' then
    return new;
  end if;
  v_date:=current_setting('shop.custom_entry_business_date',true)::date;
  select coalesce(s.timezone,'Asia/Kolkata'),coalesce(s.dashboard_reset_time,'00:00')::time
    into v_timezone,v_reset from public.shop_settings s where s.id=1;
  v_now_local:=now() at time zone v_timezone;
  v_local_timestamp:=v_date::timestamp+
    (v_now_local::time-time '00:00')+
    case when v_now_local::time<v_reset then interval '1 day' else interval '0' end;
  v_timestamp:=v_local_timestamp at time zone v_timezone;
  v_date_column:=case tg_table_name
    when 'sales' then 'sold_at'
    when 'sale_transactions' then 'created_at'
    when 'inventory_purchases' then 'purchased_at'
    when 'returns' then 'returned_at'
    else 'created_at'
  end;
  new:=jsonb_populate_record(new,jsonb_build_object(v_date_column,v_timestamp,'custom_entry',true));
  return new;
end;
$$;
revoke all on function public.apply_custom_entry_timestamp() from public,anon,authenticated;
drop trigger if exists custom_entry_audit_date on public.audit_logs;

create or replace function public.custom_entry_purchase_cost_at(
  p_product_id uuid,
  p_business_date date,
  p_before timestamptz
) returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_price numeric;
begin
  select p.shop_id into v_shop_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.is_active=true;
  if v_shop_id is null then return null; end if;

  select e.cost_per_base_unit into v_price
  from (
    select s.total_cost/nullif(s.quantity_base,0) as cost_per_base_unit, s.sold_at as event_at, 2 as priority
    from public.sales s
    join public.profiles w on w.id=s.worker_id
    where s.product_id=p_product_id and w.shop_id=v_shop_id
      and public.business_date(s.sold_at)<=p_business_date
    union all
    select i.total_cost/nullif(i.quantity_base,0) as cost_per_base_unit, i.purchased_at as event_at, 1 as priority
    from public.inventory_purchases i
    join public.profiles w on w.id=i.purchased_by
    where i.product_id=p_product_id and w.shop_id=v_shop_id
      and public.business_date(i.purchased_at)<=p_business_date
  ) e
  where e.event_at<p_before
  order by e.event_at desc,e.priority desc
  limit 1;
  return v_price;
end;
$$;
revoke all on function public.custom_entry_purchase_cost_at(uuid,date,timestamptz) from public,anon,authenticated;

-- Return the selected day’s audit rows and lifetime totals as of that day.
-- Historical audit rows created before this migration carry their date in details.
create or replace function public.get_business_day_supplement(p_business_date date)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with me as (
    select p.shop_id from public.profiles p
    where p.id=(select auth.uid()) and p.is_active=true limit 1
  ),
  audit_rows as (
    select coalesce(jsonb_agg(
      to_jsonb(a)||jsonb_build_object('profiles',coalesce(
        (select jsonb_build_object('full_name',ap.full_name) from public.profiles ap where ap.id=a.actor_id),'{}'::jsonb
      )) order by a.created_at desc
    ),'[]'::jsonb) value
    from public.audit_logs a join public.profiles actor on actor.id=a.actor_id
    where actor.shop_id=(select shop_id from me)
      and (public.business_date(a.created_at)=p_business_date
        or a.details->>'business_date'=p_business_date::text)
  ),
  lifetime_row as (
    select jsonb_build_object(
      'lifetime_sales',coalesce(sum(d.total_revenue),0),
      'lifetime_purchases',coalesce(sum(d.total_purchases+d.pre_stock_purchases),0),
      'lifetime_profit',coalesce(sum(d.total_profit),0)
    ) value
    from public.daily_financial_summaries d
    where d.shop_id=(select shop_id from me) and d.business_date<=p_business_date
  )
  select jsonb_build_object(
    'audit',(select value from audit_rows),
    'historical_lifetime',(select value from lifetime_row)
  );
$$;
revoke all on function public.get_business_day_supplement(date) from public,anon;
grant execute on function public.get_business_day_supplement(date) to authenticated;

create or replace function public.apply_custom_entry_historical_sale_cost()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_date date;
  v_today date;
  v_price numeric;
  v_unit_type text;
  v_price_unit text;
  v_allow_below_cost boolean;
  v_allow_zero_price boolean;
begin
  if coalesce(current_setting('shop.custom_entry_business_date',true),'')='' then
    return new;
  end if;
  v_date:=current_setting('shop.custom_entry_business_date',true)::date;
  v_today:=public.business_date(now());
  if v_date>=v_today then return new; end if;

  v_price:=public.custom_entry_purchase_cost_at(new.product_id,v_date,new.sold_at);
  if v_price is null then return new; end if;
  select p.unit_type,coalesce(p.weight_price_unit,'kg')
    into v_unit_type,v_price_unit
  from public.products p where p.id=new.product_id;
  if not found then return new; end if;

  -- Stored total_cost / quantity_base is the stable physical-base-unit cost
  -- (per gram for weight products), even if the product's price unit changed later.
  new.purchase_price_per_base_unit:=case when v_unit_type='weight' and v_price_unit='kg'
    then v_price*1000 else v_price end;
  new.total_cost:=round(new.quantity_base*v_price,2);
  select coalesce(s.allow_below_cost_sales,true),coalesce(s.allow_zero_price_sales,true)
    into v_allow_below_cost,v_allow_zero_price from public.shop_settings s where s.id=1;
  if not coalesce(v_allow_zero_price,true) and new.total_sale=0 then
    raise exception 'Zero-price sales are disabled in shop settings';
  end if;
  if not coalesce(v_allow_below_cost,true) and new.total_sale+0.01<new.total_cost then
    raise exception 'Sale total is below the historical purchase cost and below-cost sales are disabled';
  end if;
  new.gross_profit:=round(new.total_sale-new.total_cost,2);
  return new;
end;
$$;
revoke all on function public.apply_custom_entry_historical_sale_cost() from public,anon,authenticated;
drop trigger if exists custom_entry_historical_sale_cost on public.sales;
drop trigger if exists zzz_custom_entry_historical_sale_cost on public.sales;
create trigger zzz_custom_entry_historical_sale_cost
before insert on public.sales
for each row execute function public.apply_custom_entry_historical_sale_cost();

create or replace function public.preserve_live_prices_for_historical_purchase()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_date date;
begin
  if coalesce(current_setting('shop.custom_entry_business_date',true),'')='' then
    return new;
  end if;
  v_date:=current_setting('shop.custom_entry_business_date',true)::date;
  if v_date<public.business_date(now()) then
    new.purchase_price_per_base_unit:=old.purchase_price_per_base_unit;
    new.selling_price_per_base_unit:=old.selling_price_per_base_unit;
  end if;
  return new;
end;
$$;
revoke all on function public.preserve_live_prices_for_historical_purchase() from public,anon,authenticated;
drop trigger if exists preserve_live_prices_for_historical_purchase on public.products;
create trigger preserve_live_prices_for_historical_purchase
before update on public.products
for each row execute function public.preserve_live_prices_for_historical_purchase();



create or replace function public.rebuild_debtor_purchase_paid(p_debtor_id uuid,p_shop_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment record;
  v_purchase record;
  v_remaining numeric;
  v_take numeric;
begin
  update public.inventory_purchases i
  set credit_paid=0
  where i.debtor_id=p_debtor_id and coalesce(i.pre_stock,false)=false
    and i.purchased_by in (select p.id from public.profiles p where p.shop_id=p_shop_id);

  for v_payment in
    select dl.purchase_id,dl.amount,dl.created_at
    from public.debtor_ledger dl
    where dl.debtor_id=p_debtor_id and dl.shop_id=p_shop_id and dl.type='payment_made'
      and dl.payment_mode in ('cash','upi','split')
    order by dl.created_at,dl.id
  loop
    v_remaining:=coalesce(v_payment.amount,0);
    if v_payment.purchase_id is not null then
      update public.inventory_purchases i
      set credit_paid=least(i.credit_amount,i.credit_paid+v_remaining)
      where i.id=v_payment.purchase_id and i.debtor_id=p_debtor_id
        and coalesce(i.pre_stock,false)=false;
      continue;
    end if;

    for v_purchase in
      select i.id,i.credit_amount,i.credit_paid
      from public.inventory_purchases i
      where i.debtor_id=p_debtor_id and coalesce(i.pre_stock,false)=false
        and i.purchased_by in (select p.id from public.profiles p where p.shop_id=p_shop_id)
        and public.business_date(i.purchased_at)<=public.business_date(v_payment.created_at)
        and i.credit_amount>i.credit_paid
      order by i.purchased_at,i.id
      for update
    loop
      exit when v_remaining<=0.01;
      v_take:=least(v_remaining,v_purchase.credit_amount-v_purchase.credit_paid);
      update public.inventory_purchases
      set credit_paid=credit_paid+v_take
      where id=v_purchase.id;
      v_remaining:=v_remaining-v_take;
    end loop;
  end loop;
end;
$$;
revoke all on function public.rebuild_debtor_purchase_paid(uuid,text) from public,anon,authenticated;

create or replace function public.receive_credit_payment(
  p_creditor_id uuid,p_amount numeric,p_payment_mode text,
  p_cash_amount numeric default 0,p_upi_amount numeric default 0
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
  v_creditor public.creditors;
  v_balance_before numeric;
  v_balance_after numeric;
  v_custom_date date;
  v_cash numeric:=coalesce(p_cash_amount,0);
  v_upi numeric:=coalesce(p_upi_amount,0);
  v_id uuid;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  v_shop_id:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into v_creditor from public.creditors
  where id=p_creditor_id and shop_id=v_shop_id and is_active=true for update;
  if not found then raise exception 'Creditor not found'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;
  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if coalesce(current_setting('shop.custom_entry_business_date',true),'')<>'' then
    v_custom_date:=current_setting('shop.custom_entry_business_date',true)::date;
    select coalesce(sum(case when l.type in ('credit_sale','adjustment') then l.amount
      when l.type='payment_received' then -l.amount else 0 end),0)
      into v_balance_before from public.credit_ledger l
    where l.shop_id=v_shop_id and l.creditor_id=p_creditor_id
      and public.business_date(l.created_at)<=v_custom_date;
  else
    v_balance_before:=public.creditor_balance(p_creditor_id);
  end if;
  if v_balance_before<=0 then raise exception 'This creditor has no outstanding balance for the selected date'; end if;
  if p_amount>v_balance_before+0.01 then raise exception 'Payment exceeds outstanding balance for the selected date'; end if;

  insert into public.credit_ledger(shop_id,creditor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
  values(v_shop_id,p_creditor_id,'payment_received',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Credit payment received')
  returning id into v_id;
  v_balance_after:=v_balance_before-p_amount;
  perform public.write_audit('credit_payment_received','creditor',p_creditor_id,
    jsonb_build_object('payment_id',v_id,'amount',round(p_amount,2),'payment_mode',p_payment_mode,
      'cash_amount',round(v_cash,2),'upi_amount',round(v_upi,2),
      'previous_balance',round(v_balance_before,2),'new_balance',round(v_balance_after,2)));
  return jsonb_build_object('payment_id',v_id,'previous_balance',round(v_balance_before,2),
    'new_balance',round(v_balance_after,2));
end;
$$;
revoke execute on function public.receive_credit_payment(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.receive_credit_payment(uuid,numeric,text,numeric,numeric) to authenticated;

create or replace function public.pay_debtor(
  p_debtor_id uuid,p_amount numeric,p_payment_mode text default 'cash',
  p_cash_amount numeric default null,p_upi_amount numeric default null
) returns public.debtors
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.debtors;
  v_shop text;
  v_cash numeric;
  v_upi numeric;
  v_remaining numeric;
  v_outstanding numeric;
  v_custom_date date;
  r record;
  v_take numeric;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select * into d from public.debtors
  where id=p_debtor_id and shop_id=v_shop and is_active=true for update;
  if not found then raise exception 'Debtor not found'; end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then v_cash:=p_amount;v_upi:=0;
    elsif p_payment_mode='upi' then v_cash:=0;v_upi:=p_amount;
    else raise exception 'Split payment requires cash and UPI amounts'; end if;
  else
    v_cash:=coalesce(p_cash_amount,0);v_upi:=coalesce(p_upi_amount,0);
  end if;
  if v_cash<0 or v_upi<0 or abs((v_cash+v_upi)-p_amount)>0.01 then
    raise exception 'Cash + UPI must equal the payment amount';
  end if;

  if coalesce(current_setting('shop.custom_entry_business_date',true),'')<>'' then
    v_custom_date:=current_setting('shop.custom_entry_business_date',true)::date;
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount when type='payment_made' then -amount else 0 end),0)
      into v_outstanding from public.debtor_ledger
    where debtor_id=p_debtor_id and shop_id=v_shop
      and public.business_date(created_at)<=v_custom_date;
  else
    select coalesce(sum(case when type in ('credit_purchase','adjustment') then amount else -amount end),0)
      into v_outstanding from public.debtor_ledger
    where debtor_id=p_debtor_id and shop_id=v_shop;
  end if;
  if p_amount>v_outstanding+0.01 then raise exception 'Payment exceeds debtor outstanding balance'; end if;

  insert into public.debtor_ledger(shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
  values(v_shop,p_debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    round(v_cash,2),round(v_upi,2),(select auth.uid()),'Debtor payment');

  if v_custom_date is not null then
    perform public.rebuild_debtor_purchase_paid(p_debtor_id,v_shop);
  else
    v_remaining:=p_amount;
    for r in
      select id,credit_amount,credit_paid from public.inventory_purchases
      where debtor_id=p_debtor_id
        and purchased_by in (select id from public.profiles where shop_id=v_shop)
        and coalesce(pre_stock,false)=false and credit_amount>credit_paid
      order by purchased_at,id for update
    loop
      exit when v_remaining<=0.01;
      v_take:=least(v_remaining,r.credit_amount-r.credit_paid);
      update public.inventory_purchases set credit_paid=credit_paid+v_take where id=r.id;
      v_remaining:=v_remaining-v_take;
    end loop;
  end if;

  perform public.write_audit('debtor_payment','debtor',p_debtor_id,
    jsonb_build_object('amount',p_amount,'payment_mode',p_payment_mode,'cash_amount',v_cash,'upi_amount',v_upi));
  return d;
end;
$$;
revoke all on function public.pay_debtor(uuid,numeric,text,numeric,numeric) from public,anon;
grant execute on function public.pay_debtor(uuid,numeric,text,numeric,numeric) to authenticated;

-- A direct per-invoice payment can't be reconstructed safely as of an earlier
-- day from the existing invoice cache. Historical supplier payments therefore
-- use the account-level Debtor Payments action, which has a dated ledger.
create or replace function public.pay_purchase_credit(
  p_purchase_id uuid,p_amount numeric,p_payment_mode text default 'cash'
) returns public.inventory_purchases
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.inventory_purchases;
  v_shop text;
  v_cash numeric:=0;
  v_upi numeric:=0;
begin
  if coalesce(current_setting('shop.custom_entry_business_date',true),'')<>'' then
    raise exception 'For a historical date, record this under Debtor Payments so the account ledger is dated correctly';
  end if;
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));
  select i.* into r from public.inventory_purchases i
  join public.profiles p on p.id=i.purchased_by
  where i.id=p_purchase_id and p.shop_id=v_shop for update;
  if not found then raise exception 'Purchase not found'; end if;
  if r.pre_stock then raise exception 'Pre-stock records cannot have purchase credit'; end if;
  if r.debtor_id is null then raise exception 'Purchase credit has no supplier account'; end if;
  if p_amount>(r.credit_amount-r.credit_paid)+0.01 then raise exception 'Payment exceeds purchase credit balance'; end if;
  if p_payment_mode='cash' then v_cash:=round(p_amount,2);
  elsif p_payment_mode='upi' then v_upi:=round(p_amount,2);
  else raise exception 'Split purchase-credit payment requires cash and UPI amounts'; end if;

  insert into public.debtor_ledger(shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,purchase_id,worker_id,notes)
  values(v_shop,r.debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    v_cash,v_upi,
    r.id,(select auth.uid()),'Purchase credit payment');
  update public.inventory_purchases set credit_paid=credit_paid+p_amount where id=r.id returning * into r;
  perform public.write_audit('purchase_credit_paid','inventory_purchase',r.id,
    jsonb_build_object('amount',round(p_amount,2),'payment_mode',p_payment_mode,
      'cash_amount',v_cash,'upi_amount',v_upi,'debtor_id',r.debtor_id));
  return r;
end;
$$;
revoke all on function public.pay_purchase_credit(uuid,numeric,text) from public,anon;
grant execute on function public.pay_purchase_credit(uuid,numeric,text) to authenticated;

create or replace function public.record_purchase_return(
  p_product_id uuid,p_quantity_base numeric,p_quantity_display numeric,p_return_unit text,
  p_return_price_per_base_unit numeric,p_payment_mode text default 'cash',
  p_source_id uuid default null,p_reason text default '',p_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  p public.products; src public.inventory_purchases; total numeric; v_id uuid; debtor uuid; v_shop text;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_return_price_per_base_unit<0 then raise exception 'Invalid return'; end if;
  if p_payment_mode not in ('cash','upi','credit_adjustment') then raise exception 'Invalid return payment mode'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if p_return_unit<>'piece' or p_quantity_display<>p_quantity_base or mod(p_quantity_base,1)<>0 then raise exception 'Piece return must be whole pieces'; end if;
  else
    if p_return_unit not in ('grams','kg') then raise exception 'Weight return must use grams or kg'; end if;
    if p_return_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg return'; end if;
    if p_return_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram return'; end if;
  end if;
  if p.current_stock_base<p_quantity_base then raise exception 'Insufficient stock for purchase return'; end if;
  if p_source_id is not null then
    select * into src from public.inventory_purchases where id=p_source_id and product_id=p_product_id for share;
    if not found then raise exception 'Original purchase not found'; end if;
    if p_quantity_base > src.quantity_base - coalesce((select sum(r.quantity_base) from public.returns r where r.return_type='purchase' and r.source_id=src.id and (coalesce(current_setting('shop.custom_entry_business_date',true),'')='' or public.business_date(r.returned_at)<=current_setting('shop.custom_entry_business_date',true)::date)),0)
      then raise exception 'Purchase return exceeds original purchase quantity'; end if;
    debtor:=src.debtor_id;
  else debtor:=p_account_id; end if;
  if p_payment_mode='credit_adjustment' and debtor is null then raise exception 'Select the supplier/debtor for a credit adjustment'; end if;
  total:=case when p.unit_type='weight' then case when coalesce(p.weight_price_unit,'kg')='grams' then round(p_quantity_base*p_return_price_per_base_unit,2) else round((p_quantity_base/1000)*p_return_price_per_base_unit,2) end else round(p_quantity_base*p_return_price_per_base_unit,2) end;
  v_shop:=(select shop_id from public.profiles where id=auth.uid());
  insert into public.returns(shop_id,return_type,product_id,product_name_snapshot,quantity_base,quantity_display,return_unit,return_price_per_base_unit,total_amount,cost_amount,profit_impact,payment_mode,cash_amount,upi_amount,credit_amount,source_id,debtor_id,reason,returned_by)
  values(v_shop,'purchase',p_product_id,p.name,p_quantity_base,p_quantity_display,p_return_unit,p_return_price_per_base_unit,total,total,0,p_payment_mode,case when p_payment_mode='cash' then total else 0 end,case when p_payment_mode='upi' then total else 0 end,case when p_payment_mode='credit_adjustment' then total else 0 end,p_source_id,debtor,trim(p_reason),auth.uid()) returning id into v_id;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base-p_quantity_base,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  if p_payment_mode='credit_adjustment' then
    insert into public.debtor_ledger(shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
    values(v_shop,debtor,'payment_made',total,'credit',0,0,auth.uid(),'Purchase return');
  end if;
  perform public.write_audit('purchase_return','return',v_id,jsonb_build_object('total',total,'quantity_base',p_quantity_base,'source_id',p_source_id));
  return v_id;
end;
$$;
create or replace function public.record_sale_return(
  p_product_id uuid,p_quantity_base numeric,p_quantity_display numeric,p_return_unit text,
  p_return_price_per_base_unit numeric,p_payment_mode text default 'cash',
  p_source_id uuid default null,p_reason text default '',p_account_id uuid default null
) returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  p public.products; src public.sales; total numeric; cost numeric; profit numeric; v_id uuid; creditor uuid; v_shop text;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_return_price_per_base_unit<0 then raise exception 'Invalid return'; end if;
  if p_payment_mode not in ('cash','upi','credit_adjustment') then raise exception 'Invalid return payment mode'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if p_return_unit<>'piece' or p_quantity_display<>p_quantity_base or mod(p_quantity_base,1)<>0 then raise exception 'Piece return must be whole pieces'; end if;
  else
    if p_return_unit not in ('grams','kg') then raise exception 'Weight sale return must use grams or kg'; end if;
    if p_return_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg return'; end if;
    if p_return_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram return'; end if;
  end if;
  if p_source_id is not null then
    select * into src from public.sales where id=p_source_id and product_id=p_product_id and not voided for share;
    if not found then raise exception 'Original sale not found'; end if;
    if p_quantity_base > src.quantity_base - coalesce((select sum(r.quantity_base) from public.returns r where r.return_type='sale' and r.source_id=src.id and (coalesce(current_setting('shop.custom_entry_business_date',true),'')='' or public.business_date(r.returned_at)<=current_setting('shop.custom_entry_business_date',true)::date)),0)
      then raise exception 'Sale return exceeds original sold quantity'; end if;
    cost:=case when src.quantity_base>0 then round(src.total_cost/src.quantity_base*p_quantity_base,2) else 0 end;
    select st.creditor_id into creditor from public.sale_transactions st where st.id=src.transaction_id;
  else
    cost:=case when p.unit_type='weight' then case when coalesce(p.weight_price_unit,'kg')='grams' then round(p_quantity_base*p.purchase_price_per_base_unit,2) else round((p_quantity_base/1000)*p.purchase_price_per_base_unit,2) end else round(p_quantity_base*p.purchase_price_per_base_unit,2) end;
    creditor:=p_account_id;
  end if;
  if p_payment_mode='credit_adjustment' and creditor is null then raise exception 'Select the customer/creditor for a credit adjustment'; end if;
  total:=case when p.unit_type='weight' then case when coalesce(p.weight_price_unit,'kg')='grams' then round(p_quantity_base*p_return_price_per_base_unit,2) else round((p_quantity_base/1000)*p_return_price_per_base_unit,2) end else round(p_quantity_base*p_return_price_per_base_unit,2) end;
  profit:=-(total-cost);
  v_shop:=(select shop_id from public.profiles where id=auth.uid());
  insert into public.returns(shop_id,return_type,product_id,product_name_snapshot,quantity_base,quantity_display,return_unit,return_price_per_base_unit,total_amount,cost_amount,profit_impact,payment_mode,cash_amount,upi_amount,credit_amount,source_id,creditor_id,reason,returned_by)
  values(v_shop,'sale',p_product_id,p.name,p_quantity_base,p_quantity_display,p_return_unit,p_return_price_per_base_unit,total,cost,profit,p_payment_mode,case when p_payment_mode='cash' then total else 0 end,case when p_payment_mode='upi' then total else 0 end,case when p_payment_mode='credit_adjustment' then total else 0 end,p_source_id,creditor,trim(p_reason),auth.uid()) returning id into v_id;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base+p_quantity_base,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  if p_payment_mode='credit_adjustment' then
    insert into public.credit_ledger(shop_id,creditor_id,type,amount,payment_mode,cash_amount,upi_amount,worker_id,notes)
    values(v_shop,creditor,'payment_received',total,'credit',0,0,auth.uid(),'Sale return credit adjustment');
  end if;
  perform public.write_audit('sale_return','return',v_id,jsonb_build_object('total',total,'cost',cost,'profit_impact',profit,'source_id',p_source_id));
  return v_id;
end;
$$;

revoke all on function public.record_purchase_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) from public,anon;
grant execute on function public.record_purchase_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) to authenticated;
revoke all on function public.record_sale_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) from public,anon;
grant execute on function public.record_sale_return(uuid,numeric,numeric,text,numeric,text,uuid,text,uuid) to authenticated;

create or replace function public.guard_custom_entry_returns()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_date date;
  v_source_date date;
  v_cost_per_base numeric;
begin
  if coalesce(current_setting('shop.custom_entry_business_date',true),'')='' then return new; end if;
  v_date:=current_setting('shop.custom_entry_business_date',true)::date;
  if new.source_id is not null then
    if new.return_type='sale' then
      select public.business_date(s.sold_at) into v_source_date from public.sales s where s.id=new.source_id;
    elsif new.return_type='purchase' then
      select public.business_date(i.purchased_at) into v_source_date from public.inventory_purchases i where i.id=new.source_id;
    end if;
    if v_source_date is not null and v_source_date>v_date then
      raise exception 'A historical return cannot reference a sale or purchase from a later date';
    end if;
  elsif new.return_type='sale' then
    v_cost_per_base:=public.custom_entry_purchase_cost_at(new.product_id,v_date,new.returned_at);
    if v_cost_per_base is not null then
      new.cost_amount:=round(new.quantity_base*v_cost_per_base,2);
      new.profit_impact:=round(-(new.total_amount-new.cost_amount),2);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_custom_entry_returns() from public,anon,authenticated;
drop trigger if exists custom_entry_return_integrity on public.returns;
drop trigger if exists zzz_custom_entry_return_integrity on public.returns;
create trigger zzz_custom_entry_return_integrity
before insert on public.returns
for each row execute function public.guard_custom_entry_returns();

create table if not exists public.shop_management_schema_version(
  version integer primary key,
  applied_at timestamptz not null default now()
);
insert into public.shop_management_schema_version(version) values(20) on conflict(version) do nothing;
select pg_notify('pgrst','reload schema');
