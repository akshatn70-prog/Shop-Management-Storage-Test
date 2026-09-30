-- CUSTOM ENTRY + HISTORICAL REPORTING REPAIR 013
alter table public.daily_financial_summaries
  add column if not exists purchase_credit_payment_cash numeric(14,2) not null default 0,
  add column if not exists purchase_credit_payment_upi numeric(14,2) not null default 0,
  add column if not exists purchase_credit_payment_total numeric(14,2) not null default 0;

create or replace function public.prevent_custom_entry_detail_delete()
returns trigger language plpgsql security invoker set search_path=''
as $$
begin
  if old.custom_entry then return null; end if;
  return old;
end;
$$;
revoke all on function public.prevent_custom_entry_detail_delete() from public,anon,authenticated;

drop trigger if exists preserve_custom_entry_sales on public.sales;
create trigger preserve_custom_entry_sales before delete on public.sales for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_sale_transactions on public.sale_transactions;
create trigger preserve_custom_entry_sale_transactions before delete on public.sale_transactions for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_purchases on public.inventory_purchases;
create trigger preserve_custom_entry_purchases before delete on public.inventory_purchases for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_returns on public.returns;
create trigger preserve_custom_entry_returns before delete on public.returns for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_credit_ledger on public.credit_ledger;
create trigger preserve_custom_entry_credit_ledger before delete on public.credit_ledger for each row execute function public.prevent_custom_entry_detail_delete();
drop trigger if exists preserve_custom_entry_debtor_ledger on public.debtor_ledger;
create trigger preserve_custom_entry_debtor_ledger before delete on public.debtor_ledger for each row execute function public.prevent_custom_entry_detail_delete();

create or replace function public.write_audit(
  p_action text,p_entity_type text,p_entity_id uuid,p_details jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_details jsonb:=coalesce(p_details,'{}'::jsonb);
  v_custom_date text;
begin
  v_custom_date:=current_setting('shop.custom_entry_business_date',true);
  if coalesce(v_custom_date,'')<>'' then
    v_details:=v_details||jsonb_build_object(
      'custom_entry',true,'business_date',v_custom_date::date,'entry_created_at',now()
    );
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values((select auth.uid()),p_action,p_entity_type,p_entity_id,v_details);
end;
$$;
revoke all on function public.write_audit(text,text,uuid,jsonb) from public,anon;
grant execute on function public.write_audit(text,text,uuid,jsonb) to authenticated;

create or replace function public.pay_purchase_credit(
  p_purchase_id uuid,p_amount numeric,p_payment_mode text default 'cash'
) returns public.inventory_purchases
language plpgsql security definer set search_path=''
as $$
declare
  r public.inventory_purchases;
  v_shop text;
  v_cash numeric:=0;
  v_upi numeric:=0;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_amount<=0 then raise exception 'Payment amount must be positive'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Invalid payment mode'; end if;
  v_shop:=(select shop_id from public.profiles where id=(select auth.uid()));

  select i.* into r
  from public.inventory_purchases i
  join public.profiles p on p.id=i.purchased_by
  where i.id=p_purchase_id and p.shop_id=v_shop
  for update;

  if not found then raise exception 'Purchase not found'; end if;
  if r.pre_stock then raise exception 'Pre-stock records cannot have purchase credit'; end if;
  if r.debtor_id is null then raise exception 'Purchase credit has no supplier account'; end if;
  if p_amount>(r.credit_amount-r.credit_paid)+0.01 then raise exception 'Payment exceeds purchase credit balance'; end if;

  if p_payment_mode='cash' then v_cash:=round(p_amount,2);
  elsif p_payment_mode='upi' then v_upi:=round(p_amount,2);
  else raise exception 'Split purchase-credit payment requires cash and UPI amounts'; end if;

  insert into public.debtor_ledger(
    shop_id,debtor_id,type,amount,payment_mode,cash_amount,upi_amount,purchase_id,worker_id,notes
  ) values(
    v_shop,r.debtor_id,'payment_made',round(p_amount,2),p_payment_mode,
    v_cash,v_upi,r.id,(select auth.uid()),'Purchase credit payment'
  );

  update public.inventory_purchases
  set credit_paid=credit_paid+p_amount
  where id=r.id
  returning * into r;

  perform public.write_audit(
    'purchase_credit_paid','inventory_purchase',r.id,
    jsonb_build_object('amount',round(p_amount,2),'payment_mode',p_payment_mode,
      'cash_amount',v_cash,'upi_amount',v_upi,'debtor_id',r.debtor_id)
  );
  return r;
end;
$$;
revoke all on function public.pay_purchase_credit(uuid,numeric,text) from public,anon;
grant execute on function public.pay_purchase_credit(uuid,numeric,text) to authenticated;

create or replace function public.refresh_daily_financial_summary(
  p_shop_id text,p_business_date date
) returns void language plpgsql security definer set search_path=''
as $$
begin
  insert into public.daily_financial_summaries(
    shop_id,business_date,total_transactions,total_revenue,cash_sales,upi_sales,credit_sales,
    total_profit,cash_profit,upi_profit,credit_profit,creditor_amount,
    purchase_cash,purchase_upi,purchase_credit,total_purchases,pre_stock_purchases,
    sales_returns,purchase_returns,sales_return_profit_impact,
    debtor_payment_cash,debtor_payment_upi,debtor_payment_total,
    purchase_credit_payment_cash,purchase_credit_payment_upi,purchase_credit_payment_total,updated_at
  )
  select
    p_shop_id,p_business_date,coalesce(s.tx_count,0),
    round(coalesce(s.revenue,0)-coalesce(r.sales_ret,0),2),
    round(coalesce(s.cash,0)-coalesce(r.sales_cash,0),2),
    round(coalesce(s.upi,0)-coalesce(r.sales_upi,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(s.profit,0)+coalesce(r.sales_profit_impact,0),2),
    round(coalesce(s.cash_profit,0)+coalesce(r.sales_cash_profit_impact,0),2),
    round(coalesce(s.upi_profit,0)+coalesce(r.sales_upi_profit_impact,0),2),
    round(coalesce(s.credit_profit,0)+coalesce(r.sales_credit_profit_impact,0),2),
    round(coalesce(s.credit,0)-coalesce(r.sales_credit,0),2),
    round(coalesce(p.cash_purchase,0)-coalesce(r.purchase_cash,0),2),
    round(coalesce(p.upi_purchase,0)-coalesce(r.purchase_upi,0),2),
    round(coalesce(p.credit_purchase,0)-coalesce(r.purchase_credit,0),2),
    round(coalesce(p.total_purchase,0)-coalesce(r.purchase_ret,0),2),
    round(coalesce(p.pre_stock_purchase,0),2),
    round(coalesce(r.sales_ret,0),2),round(coalesce(r.purchase_ret,0),2),
    round(coalesce(r.sales_profit_impact,0),2),
    round(coalesce(d.pay_cash,0),2),round(coalesce(d.pay_upi,0),2),round(coalesce(d.pay_total,0),2),
    round(coalesce(pc.pay_cash,0),2),round(coalesce(pc.pay_upi,0),2),round(coalesce(pc.pay_total,0),2),now()
  from (select 1) seed
  left join lateral (
    select count(distinct coalesce(s.transaction_id,s.id))::integer tx_count,
      coalesce(sum(s.total_sale),0)::numeric revenue,
      coalesce(sum(s.cash_amount),0)::numeric cash,
      coalesce(sum(s.upi_amount),0)::numeric upi,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split')
        then greatest(s.total_sale-s.cash_amount-s.upi_amount,0) else 0 end),0)::numeric credit,
      coalesce(sum(s.gross_profit),0)::numeric profit,
      coalesce(sum(case when s.payment_mode='cash' then s.gross_profit
        when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.cash_amount/s.total_sale else 0 end),0)::numeric cash_profit,
      coalesce(sum(case when s.payment_mode='upi' then s.gross_profit
        when s.payment_mode='split' and s.total_sale>0 then s.gross_profit*s.upi_amount/s.total_sale else 0 end),0)::numeric upi_profit,
      coalesce(sum(case when s.payment_mode in ('credit','credit_split') and s.total_sale>0
        then s.gross_profit*greatest(s.total_sale-s.cash_amount-s.upi_amount,0)/s.total_sale else 0 end),0)::numeric credit_profit
    from public.sales s join public.profiles w on w.id=s.worker_id
    where w.shop_id=p_shop_id and not s.voided and public.business_date(s.sold_at)=p_business_date
  ) s on true
  left join lateral (
    select
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('cash','split') then i.cash_amount else 0 end),0)::numeric cash_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) and i.payment_mode in ('upi','split') then i.upi_amount else 0 end),0)::numeric upi_purchase,
      coalesce(sum(case when not coalesce(i.pre_stock,false) then i.credit_amount else 0 end),0)::numeric credit_purchase,
      coalesce(sum(case when i.payment_mode in ('cash','upi','split','credit') then i.total_cost else 0 end),0)::numeric total_purchase,
      coalesce(sum(case when coalesce(i.pre_stock,false) then i.total_cost else 0 end),0)::numeric pre_stock_purchase
    from public.inventory_purchases i join public.profiles w on w.id=i.purchased_by
    where w.shop_id=p_shop_id and public.business_date(i.purchased_at)=p_business_date
  ) p on true
  left join lateral (
    select coalesce(sum(case when type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and public.business_date(dl.created_at)=p_business_date
  ) d on true
  left join lateral (
    select coalesce(sum(case when purchase_id is not null and type='payment_made' then cash_amount else 0 end),0)::numeric pay_cash,
      coalesce(sum(case when purchase_id is not null and type='payment_made' then upi_amount else 0 end),0)::numeric pay_upi,
      coalesce(sum(case when purchase_id is not null and type='payment_made' then amount else 0 end),0)::numeric pay_total
    from public.debtor_ledger dl
    where dl.shop_id=p_shop_id and public.business_date(dl.created_at)=p_business_date
  ) pc on true
  left join lateral (
    select
      coalesce(sum(case when return_type='sale' then total_amount else 0 end),0)::numeric sales_ret,
      coalesce(sum(case when return_type='sale' then cash_amount else 0 end),0)::numeric sales_cash,
      coalesce(sum(case when return_type='sale' then upi_amount else 0 end),0)::numeric sales_upi,
      coalesce(sum(case when return_type='sale' then credit_amount else 0 end),0)::numeric sales_credit,
      coalesce(sum(case when return_type='sale' then profit_impact else 0 end),0)::numeric sales_profit_impact,
      coalesce(sum(case when return_type='sale' and cash_amount>0 then profit_impact else 0 end),0)::numeric sales_cash_profit_impact,
      coalesce(sum(case when return_type='sale' and upi_amount>0 then profit_impact else 0 end),0)::numeric sales_upi_profit_impact,
      coalesce(sum(case when return_type='sale' and credit_amount>0 then profit_impact else 0 end),0)::numeric sales_credit_profit_impact,
      coalesce(sum(case when return_type='purchase' then total_amount else 0 end),0)::numeric purchase_ret,
      coalesce(sum(case when return_type='purchase' then cash_amount else 0 end),0)::numeric purchase_cash,
      coalesce(sum(case when return_type='purchase' then upi_amount else 0 end),0)::numeric purchase_upi,
      coalesce(sum(case when return_type='purchase' then credit_amount else 0 end),0)::numeric purchase_credit
    from public.returns
    where shop_id=p_shop_id and public.business_date(returned_at)=p_business_date
  ) r on true
  on conflict(shop_id,business_date) do update set
    total_transactions=excluded.total_transactions,total_revenue=excluded.total_revenue,
    cash_sales=excluded.cash_sales,upi_sales=excluded.upi_sales,credit_sales=excluded.credit_sales,
    total_profit=excluded.total_profit,cash_profit=excluded.cash_profit,upi_profit=excluded.upi_profit,
    credit_profit=excluded.credit_profit,creditor_amount=excluded.creditor_amount,
    purchase_cash=excluded.purchase_cash,purchase_upi=excluded.purchase_upi,purchase_credit=excluded.purchase_credit,
    total_purchases=excluded.total_purchases,pre_stock_purchases=excluded.pre_stock_purchases,
    sales_returns=excluded.sales_returns,purchase_returns=excluded.purchase_returns,
    sales_return_profit_impact=excluded.sales_return_profit_impact,
    debtor_payment_cash=excluded.debtor_payment_cash,debtor_payment_upi=excluded.debtor_payment_upi,
    debtor_payment_total=excluded.debtor_payment_total,
    purchase_credit_payment_cash=excluded.purchase_credit_payment_cash,
    purchase_credit_payment_upi=excluded.purchase_credit_payment_upi,
    purchase_credit_payment_total=excluded.purchase_credit_payment_total,
    updated_at=now();
end;
$$;
revoke all on function public.refresh_daily_financial_summary(text,date) from public,anon,authenticated;
grant execute on function public.refresh_daily_financial_summary(text,date) to authenticated;

create or replace function public.sales_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_shop text;
begin
 select shop_id into v_shop from public.profiles where id=coalesce(new.worker_id,old.worker_id);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.sold_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.sold_at)); end if;
 perform public.refresh_lifetime_financial_summary(v_shop); return coalesce(new,old);
end;
$$;
drop trigger if exists sales_financial_aggregate_trigger on public.sales;
create trigger sales_financial_aggregate_trigger after insert or update or delete on public.sales for each row execute function public.sales_financial_aggregate_trigger();

create or replace function public.purchase_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_shop text;
begin
 select shop_id into v_shop from public.profiles where id=coalesce(new.purchased_by,old.purchased_by);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.purchased_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.purchased_at)); end if;
 perform public.refresh_lifetime_financial_summary(v_shop); return coalesce(new,old);
end;
$$;
drop trigger if exists purchase_financial_aggregate_trigger on public.inventory_purchases;
create trigger purchase_financial_aggregate_trigger after insert or update or delete on public.inventory_purchases for each row execute function public.purchase_financial_aggregate_trigger();

create or replace function public.debtor_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_shop text;
begin
 v_shop:=coalesce(new.shop_id,old.shop_id);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.created_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.created_at)); end if;
 return coalesce(new,old);
end;
$$;
drop trigger if exists debtor_financial_aggregate_trigger on public.debtor_ledger;
create trigger debtor_financial_aggregate_trigger after insert or update or delete on public.debtor_ledger for each row execute function public.debtor_financial_aggregate_trigger();

create or replace function public.returns_financial_aggregate_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_shop text;
begin
 v_shop:=coalesce(new.shop_id,old.shop_id);
 if old is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(old.returned_at)); end if;
 if new is not null then perform public.refresh_daily_financial_summary(v_shop,public.business_date(new.returned_at)); end if;
 perform public.refresh_lifetime_financial_summary(v_shop); return coalesce(new,old);
end;
$$;
drop trigger if exists returns_financial_aggregate_trigger on public.returns;
create trigger returns_financial_aggregate_trigger after insert or update or delete on public.returns for each row execute function public.returns_financial_aggregate_trigger();

create or replace function public.creditor_aggregate_trigger()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_shop text;
begin
 v_shop:=coalesce(new.shop_id,old.shop_id);
 if old is not null then perform public.refresh_creditor_daily_aggregate(v_shop,old.creditor_id,public.business_date(old.created_at)); end if;
 if new is not null then perform public.refresh_creditor_daily_aggregate(v_shop,new.creditor_id,public.business_date(new.created_at)); end if;
 return coalesce(new,old);
end;
$$;
drop trigger if exists creditor_aggregate_trigger on public.credit_ledger;
create trigger creditor_aggregate_trigger after insert or update or delete on public.credit_ledger for each row execute function public.creditor_aggregate_trigger();

do $$
declare r record;
begin
 for r in
   select distinct w.shop_id,public.business_date(s.sold_at) business_date
   from public.sales s join public.profiles w on w.id=s.worker_id
   where w.shop_id is not null
 loop perform public.refresh_daily_financial_summary(r.shop_id,r.business_date); end loop;
 for r in
   select distinct w.shop_id,public.business_date(p.purchased_at) business_date
   from public.inventory_purchases p join public.profiles w on w.id=p.purchased_by
   where w.shop_id is not null
 loop perform public.refresh_daily_financial_summary(r.shop_id,r.business_date); end loop;
 for r in
   select distinct d.shop_id,public.business_date(d.created_at) business_date
   from public.debtor_ledger d
 loop perform public.refresh_daily_financial_summary(r.shop_id,r.business_date); end loop;
 for r in
   select distinct ret.shop_id,public.business_date(ret.returned_at) business_date
   from public.returns ret
 loop perform public.refresh_daily_financial_summary(r.shop_id,r.business_date); end loop;
 for r in
   select distinct c.shop_id,public.business_date(c.created_at) business_date
   from public.credit_ledger c
 loop perform public.refresh_daily_financial_summary(r.shop_id,r.business_date); end loop;
 for r in select distinct shop_id from public.daily_financial_summaries
 loop perform public.refresh_lifetime_financial_summary(r.shop_id); end loop;
end;
$$;

select pg_notify('pgrst','reload schema');
create table if not exists public.shop_management_schema_version(version integer primary key,applied_at timestamptz not null default now());
insert into public.shop_management_schema_version(version) values(13) on conflict(version) do nothing;
