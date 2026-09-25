-- Incremental migration: split cash+UPI payments and owner-only start-over reset.
-- Safe to run whether the earlier 20260924 sales migration was already applied or not.

alter table public.sales
  add column if not exists payment_mode text not null default 'cash';

alter table public.sales
  add column if not exists cash_amount numeric(14,2) not null default 0;

alter table public.sales
  add column if not exists upi_amount numeric(14,2) not null default 0;

alter table public.sales
  drop constraint if exists sales_payment_mode_check;

alter table public.sales
  add constraint sales_payment_mode_check
  check (payment_mode in ('cash','upi','split'));

update public.sales
set cash_amount = case when payment_mode='cash' then total_sale else 0 end,
    upi_amount  = case when payment_mode='upi' then total_sale else 0 end
where cash_amount=0 and upi_amount=0;

update public.sales
set payment_mode='split'
where cash_amount>0 and upi_amount>0;

alter table public.sales
  drop constraint if exists sales_payment_split_check;

alter table public.sales
  add constraint sales_payment_split_check
  check (cash_amount >= 0 and upi_amount >= 0 and cash_amount + upi_amount = total_sale);

create index if not exists sales_payment_mode_idx on public.sales(payment_mode);

drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric);
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text);
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric);

create or replace function public.record_sale(
  p_product_id uuid,
  p_worker_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_sold_unit text,
  p_selling_price_per_base_unit numeric,
  p_payment_mode text default 'cash',
  p_cash_amount numeric default null,
  p_upi_amount numeric default null
) returns public.sales
language plpgsql security definer set search_path = ''
as $$
declare
  p public.products;
  total_sale numeric;
  total_cost numeric;
  gross numeric;
  cash_paid numeric;
  upi_paid numeric;
  actual_payment_mode text;
  result_row public.sales;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if p_worker_id <> (select auth.uid()) and not (select public.is_owner()) then raise exception 'Worker can only record sales for self'; end if;
  if not exists (select 1 from public.profiles where id=p_worker_id and is_active=true) then raise exception 'Worker account is inactive'; end if;
  if p_quantity_base<=0 or p_quantity_display<=0 or p_selling_price_per_base_unit<0 then raise exception 'Invalid sale'; end if;
  if p_payment_mode not in ('cash','upi','split') then raise exception 'Payment mode must be cash, upi or split'; end if;

  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;

  if p.unit_type='piece' then
    if p_quantity_base<>p_quantity_display or mod(p_quantity_base,1)<>0 or p_sold_unit<>'piece' then raise exception 'Piece quantity must be a whole number and sold in pieces'; end if;
  else
    if p_sold_unit not in ('grams','kg') then raise exception 'Weight products must be sold in grams or kg'; end if;
    if p_sold_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg quantity'; end if;
    if p_sold_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram quantity'; end if;
  end if;

  if p.current_stock_base<p_quantity_base then raise exception 'Insufficient stock'; end if;

  if p.unit_type='piece' then
    total_sale:=p_quantity_base*p_selling_price_per_base_unit;
    total_cost:=p_quantity_base*p.purchase_price_per_base_unit;
  else
    total_sale:=(p_quantity_base/1000)*p_selling_price_per_base_unit;
    total_cost:=(p_quantity_base/1000)*p.purchase_price_per_base_unit;
  end if;
  gross:=total_sale-total_cost;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then cash_paid:=total_sale; upi_paid:=0;
    elsif p_payment_mode='upi' then cash_paid:=0; upi_paid:=total_sale;
    else raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    cash_paid:=coalesce(p_cash_amount,0);
    upi_paid:=coalesce(p_upi_amount,0);
  end if;

  if cash_paid<0 or upi_paid<0 or abs((cash_paid+upi_paid)-total_sale)>0.01 then raise exception 'Cash + UPI must equal the sale total'; end if;

  actual_payment_mode:=case
    when cash_paid>0 and upi_paid>0 then 'split'
    when upi_paid>0 then 'upi'
    else 'cash'
  end;

  insert into public.sales(
    product_id,worker_id,quantity_base,quantity_display,sold_unit,payment_mode,
    cash_amount,upi_amount,selling_price_per_base_unit,purchase_price_per_base_unit,
    total_sale,total_cost,gross_profit
  )
  values(
    p_product_id,p_worker_id,p_quantity_base,p_quantity_display,p_sold_unit,actual_payment_mode,
    round(cash_paid,2),round(upi_paid,2),p_selling_price_per_base_unit,p.purchase_price_per_base_unit,
    round(total_sale,2),round(total_cost,2),round(gross,2)
  )
  returning * into result_row;

  update public.products set current_stock_base=current_stock_base-p_quantity_base, updated_at=now() where id=p_product_id;

  perform public.write_audit('sale_created','sale',result_row.id,
    jsonb_build_object(
      'product_id',p_product_id,'quantity_base',p_quantity_base,'quantity_display',p_quantity_display,
      'sold_unit',p_sold_unit,'payment_mode',actual_payment_mode,
      'cash_amount',round(cash_paid,2),'upi_amount',round(upi_paid,2),
      'selling_price_per_base_unit',p_selling_price_per_base_unit,'total_sale',round(total_sale,2)
    ));
  return result_row;
end;
$$;

grant execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) to authenticated;

create or replace function public.clear_all_shop_data()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  truncate table
    public.day_end_summary_lines,
    public.day_end_summaries,
    public.daily_closings,
    public.sales,
    public.inventory_purchases,
    public.audit_logs
    restart identity;
  update public.products set current_stock_base=0, updated_at=now() where id is not null;
  truncate table public.audit_logs restart identity;
end;
$$;

revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;
