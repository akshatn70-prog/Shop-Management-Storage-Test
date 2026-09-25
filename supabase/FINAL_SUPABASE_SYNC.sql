-- ============================================================
-- SOURCE: supabase/migrations/20260924_sales_improvements.sql
-- ============================================================
-- Shop Management: sales, worker visibility, split payments and reset migration
-- Run this ONCE in the existing Supabase project after the app code update.

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

-- Normalize old records.
update public.sales
set sold_unit='piece'
where sold_unit is null or sold_unit='product';

update public.sales
set cash_amount = case when payment_mode='cash' then total_sale else 0 end,
    upi_amount  = case when payment_mode='upi' then total_sale else 0 end
where cash_amount=0 and upi_amount=0;

-- Any legacy row whose two amounts are already populated is treated as split.
update public.sales
set payment_mode='split'
where cash_amount > 0 and upi_amount > 0;

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
  if p_worker_id <> (select auth.uid()) and not (select public.is_owner()) then
    raise exception 'Worker can only record sales for self';
  end if;
  if not exists (select 1 from public.profiles where id=p_worker_id and is_active=true) then
    raise exception 'Worker account is inactive';
  end if;
  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_selling_price_per_base_unit < 0 then
    raise exception 'Invalid sale';
  end if;
  if p_payment_mode not in ('cash','upi','split') then
    raise exception 'Payment mode must be cash, upi or split';
  end if;

  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;

  if p.unit_type='piece' then
    if p_quantity_base <> p_quantity_display or mod(p_quantity_base,1) <> 0 or p_sold_unit <> 'piece' then
      raise exception 'Piece quantity must be a whole number and sold in pieces';
    end if;
  else
    if p_sold_unit not in ('grams','kg') then raise exception 'Weight products must be sold in grams or kg'; end if;
    if p_sold_unit='kg' and p_quantity_base <> p_quantity_display*1000 then raise exception 'Invalid kg quantity'; end if;
    if p_sold_unit='grams' and p_quantity_base <> p_quantity_display then raise exception 'Invalid gram quantity'; end if;
  end if;

  if p.current_stock_base < p_quantity_base then raise exception 'Insufficient stock'; end if;

  if p.unit_type='piece' then
    total_sale := p_quantity_base*p_selling_price_per_base_unit;
    total_cost := p_quantity_base*p.purchase_price_per_base_unit;
  else
    total_sale := (p_quantity_base/1000)*p_selling_price_per_base_unit;
    total_cost := (p_quantity_base/1000)*p.purchase_price_per_base_unit;
  end if;
  gross := total_sale-total_cost;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then
      cash_paid:=total_sale; upi_paid:=0;
    elsif p_payment_mode='upi' then
      cash_paid:=0; upi_paid:=total_sale;
    else
      raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    cash_paid:=coalesce(p_cash_amount,0);
    upi_paid:=coalesce(p_upi_amount,0);
  end if;

  if cash_paid<0 or upi_paid<0 or abs((cash_paid+upi_paid)-total_sale)>0.01 then
    raise exception 'Cash + UPI must equal the sale total';
  end if;

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

  update public.products
  set current_stock_base=current_stock_base-p_quantity_base, updated_at=now()
  where id=p_product_id;

  perform public.write_audit('sale_created','sale',result_row.id,
    jsonb_build_object(
      'product_id',p_product_id,
      'quantity_base',p_quantity_base,
      'quantity_display',p_quantity_display,
      'sold_unit',p_sold_unit,
      'payment_mode',actual_payment_mode,
      'cash_amount',round(cash_paid,2),
      'upi_amount',round(upi_paid,2),
      'selling_price_per_base_unit',p_selling_price_per_base_unit,
      'total_sale',round(total_sale,2)
    ));
  return result_row;
end;
$$;

revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric) from public, anon;
revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text) from public, anon;
revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) from public, anon;
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

  update public.products
  set current_stock_base=0, updated_at=now();

  truncate table public.audit_logs restart identity;
end;
$$;

revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;

-- Cleaner product audit: ignore automatic stock/timestamp-only changes.
create or replace function public.audit_row_change()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if TG_TABLE_NAME='products'
     and TG_OP='UPDATE'
     and OLD.name is not distinct from NEW.name
     and OLD.purchase_price_per_base_unit is not distinct from NEW.purchase_price_per_base_unit
     and OLD.selling_price_per_base_unit is not distinct from NEW.selling_price_per_base_unit
     and OLD.low_stock_threshold_base is not distinct from NEW.low_stock_threshold_base
     and OLD.is_active is not distinct from NEW.is_active
  then
    return NEW;
  end if;

  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(
    (select auth.uid()),
    lower(TG_OP),
    TG_TABLE_NAME,
    case when TG_OP='DELETE' then OLD.id else NEW.id end,
    jsonb_build_object('new',to_jsonb(NEW),'old',to_jsonb(OLD))
  );
  if TG_OP='DELETE' then return OLD; end if;
  return NEW;
end;
$$;

revoke execute on function public.audit_row_change() from public, anon, authenticated;

drop trigger if exists audit_products on public.products;
create trigger audit_products after insert or update or delete on public.products
for each row execute function public.audit_row_change();


-- ============================================================
-- SOURCE: supabase/migrations/20260924123000_sales_split_reset.sql
-- ============================================================
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


-- ============================================================
-- SOURCE: supabase/migrations/20260924150000_day_end_payments.sql
-- ============================================================
-- Day-end payment/reconciliation improvements.
-- Adds cash/UPI received to day-end summaries, exposes submitted details,
-- allocates those payments across confirmed sales, and creates the worker
-- daily closing from the submitted summary.

alter table public.day_end_summaries
  add column if not exists expected_total numeric(14,2) not null default 0,
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;

-- Existing pre-payment submissions cannot have their Cash/UPI split inferred safely.
-- Preserve their entered quantities but return those submitted summaries to draft
-- so the worker can enter the actual Cash and UPI received before resubmitting.
update public.day_end_summaries s
set expected_total = coalesce((
  select sum(case
    when l.sold_unit='kg' then l.quantity_display*l.selling_price_per_base_unit
    when l.sold_unit='grams' then (l.quantity_display/1000)*l.selling_price_per_base_unit
    else l.quantity_display*l.selling_price_per_base_unit
  end)
  from public.day_end_summary_lines l
  where l.summary_id=s.id
),0),
status = case when s.status='submitted' and s.cash_amount + s.upi_amount = 0 then 'draft' else s.status end,
submitted_at = case when s.status='submitted' and s.cash_amount + s.upi_amount = 0 then null else s.submitted_at end
where s.status='submitted';

alter table public.day_end_summaries
  drop constraint if exists day_end_payment_split_check;

alter table public.day_end_summaries
  add constraint day_end_payment_split_check
  check (expected_total >= 0 and cash_amount >= 0 and upi_amount >= 0 and cash_amount + upi_amount = expected_total);

create or replace function public.submit_day_end_summary(p_summary_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.day_end_summaries;
  total_expected numeric(14,2);
  worker_id uuid;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;

  select * into s from public.day_end_summaries
  where id=p_summary_id
  for update;

  if not found or (s.worker_id <> (select auth.uid()) and not (select public.is_owner())) then
    raise exception 'Summary not found or unauthorized';
  end if;
  if s.status <> 'draft' then raise exception 'Summary is not editable'; end if;

  select coalesce(sum(
    case
      when l.sold_unit='kg' then (l.quantity_display * 1000 / 1000) * l.selling_price_per_base_unit
      when l.sold_unit='grams' then (l.quantity_display / 1000) * l.selling_price_per_base_unit
      else l.quantity_display * l.selling_price_per_base_unit
    end
  ),0)
  into total_expected
  from public.day_end_summary_lines l
  where l.summary_id=p_summary_id;

  if total_expected <= 0 then raise exception 'Summary must contain at least one sale'; end if;
  if s.cash_amount < 0 or s.upi_amount < 0 then raise exception 'Cash and UPI cannot be negative'; end if;
  if abs((s.cash_amount + s.upi_amount) - total_expected) > 0.01 then
    raise exception 'Cash + UPI must equal the day-end total of %', round(total_expected,2);
  end if;

  update public.day_end_summaries
  set status='submitted', expected_total=round(total_expected,2), submitted_at=now()
  where id=p_summary_id;

  insert into public.daily_closings(
    business_date, worker_id, expected_total, cash_amount, upi_amount, status, submitted_at
  )
  values(
    s.business_date, s.worker_id, round(total_expected,2), round(s.cash_amount,2), round(s.upi_amount,2), 'submitted', now()
  )
  on conflict (business_date, worker_id) do update
  set expected_total=excluded.expected_total,
      cash_amount=excluded.cash_amount,
      upi_amount=excluded.upi_amount,
      status=case when public.daily_closings.status in ('approved','locked') then public.daily_closings.status else 'submitted' end,
      submitted_at=case when public.daily_closings.status in ('approved','locked') then public.daily_closings.submitted_at else excluded.submitted_at end;

  perform public.write_audit('day_end_submitted','day_end_summary',p_summary_id,
    jsonb_build_object('expected_total',round(total_expected,2),'cash_amount',round(s.cash_amount,2),'upi_amount',round(s.upi_amount,2)));
end;
$$;

create or replace function public.confirm_day_end_summary(p_summary_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.day_end_summaries;
  l record;
  line_total numeric;
  remaining_total numeric;
  remaining_cash numeric;
  remaining_upi numeric;
  line_cash numeric;
  line_upi numeric;
  line_index integer := 0;
  line_count integer;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  select * into s from public.day_end_summaries where id=p_summary_id for update;
  if not found or s.status <> 'submitted' then raise exception 'Summary not submitted'; end if;

  select count(*) into line_count from public.day_end_summary_lines where summary_id=p_summary_id;
  remaining_total := s.expected_total;
  remaining_cash := s.cash_amount;
  remaining_upi := s.upi_amount;

  for l in select * from public.day_end_summary_lines where summary_id=p_summary_id order by created_at loop
    line_index := line_index + 1;
    if l.sold_unit='kg' then
      line_total := (l.quantity_display * l.selling_price_per_base_unit);
    elsif l.sold_unit='grams' then
      line_total := (l.quantity_display / 1000) * l.selling_price_per_base_unit;
    else
      line_total := l.quantity_display * l.selling_price_per_base_unit;
    end if;

    if line_index = line_count then
      line_cash := remaining_cash;
      line_upi := remaining_upi;
    else
      line_cash := round(s.cash_amount * line_total / nullif(s.expected_total,0), 2);
      line_upi := round(s.upi_amount * line_total / nullif(s.expected_total,0), 2);
      remaining_cash := remaining_cash - line_cash;
      remaining_upi := remaining_upi - line_upi;
    end if;

    perform public.record_sale(
      l.product_id, s.worker_id, l.quantity_base, l.quantity_display,
      l.sold_unit, l.selling_price_per_base_unit,
      case when line_cash > 0 and line_upi > 0 then 'split' when line_upi > 0 then 'upi' else 'cash' end,
      line_cash, line_upi
    );
    remaining_total := remaining_total - line_total;
  end loop;

  update public.day_end_summaries
  set status='confirmed', confirmed_at=now(), confirmed_by=(select auth.uid())
  where id=p_summary_id;

  update public.daily_closings
  set expected_total=s.expected_total, cash_amount=s.cash_amount, upi_amount=s.upi_amount
  where business_date=s.business_date and worker_id=s.worker_id;

  perform public.write_audit('day_end_confirmed','day_end_summary',p_summary_id,
    jsonb_build_object('expected_total',s.expected_total,'cash_amount',s.cash_amount,'upi_amount',s.upi_amount));
end;
$$;

grant execute on function public.submit_day_end_summary(uuid) to authenticated;
grant execute on function public.confirm_day_end_summary(uuid) to authenticated;


-- ============================================================
-- SOURCE: supabase/migrations/20260924170000_audit_safety_fixes.sql
-- ============================================================
-- Safety/reliability patch for existing installations.
-- Does not change the current automatic sale -> stock -> day-end/closing UI flow.

alter table public.shop_settings
  add column if not exists allow_below_cost_sales boolean not null default true,
  add column if not exists allow_zero_price_sales boolean not null default true;

alter table public.day_end_summaries
  add column if not exists expected_total numeric(14,2) not null default 0,
  add column if not exists cash_amount numeric(14,2) not null default 0,
  add column if not exists upi_amount numeric(14,2) not null default 0;

alter table public.day_end_summaries drop constraint if exists day_end_payment_split_check;
alter table public.day_end_summaries
  add constraint day_end_payment_split_check
  check (expected_total >= 0 and cash_amount >= 0 and upi_amount >= 0 and cash_amount + upi_amount = expected_total);

create or replace function public.protect_last_owner()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if OLD.role='owner' and OLD.is_active=true
     and (NEW.role<>'owner' or NEW.is_active=false)
     and not exists (
       select 1 from public.profiles p
       where p.id<>OLD.id and p.role='owner' and p.is_active=true
     )
  then
    raise exception 'At least one active owner is required';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.protect_last_owner() from public, anon, authenticated;
drop trigger if exists protect_last_owner on public.profiles;
create trigger protect_last_owner before update on public.profiles
for each row execute function public.protect_last_owner();

create or replace function public.protect_product_stock_direct_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if OLD.current_stock_base is distinct from NEW.current_stock_base
     and current_setting('shop.allow_stock_change', true) is distinct from 'on'
  then
    raise exception 'Stock can only change through sale, purchase, correction or reset operations';
  end if;
  return NEW;
end;
$$;
revoke execute on function public.protect_product_stock_direct_update() from public, anon, authenticated;
drop trigger if exists protect_product_stock_direct_update on public.products;
create trigger protect_product_stock_direct_update before update on public.products
for each row execute function public.protect_product_stock_direct_update();

revoke insert on public.inventory_purchases from authenticated;

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
  if p_worker_id <> (select auth.uid()) and not (select public.is_owner()) then
    raise exception 'Worker can only record sales for self';
  end if;
  if not exists (select 1 from public.profiles where id=p_worker_id and is_active=true) then
    raise exception 'Worker account is inactive';
  end if;
  if p_quantity_base <= 0 or p_quantity_display <= 0 or p_selling_price_per_base_unit < 0 then
    raise exception 'Invalid sale';
  end if;
  if p_selling_price_per_base_unit = 0
     and not coalesce((select allow_zero_price_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Zero-price sales are disabled in shop settings';
  end if;
  if p_payment_mode not in ('cash','upi','split') then
    raise exception 'Payment mode must be cash, upi or split';
  end if;

  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;

  if p.unit_type = 'piece' then
    if p_quantity_base <> p_quantity_display or mod(p_quantity_base, 1) <> 0 or p_sold_unit <> 'piece' then
      raise exception 'Piece quantity must be a whole number and sold in pieces';
    end if;
  else
    if p_sold_unit not in ('grams','kg') then raise exception 'Weight products must be sold in grams or kg'; end if;
    if p_sold_unit = 'kg' and p_quantity_base <> p_quantity_display * 1000 then raise exception 'Invalid kg quantity'; end if;
    if p_sold_unit = 'grams' and p_quantity_base <> p_quantity_display then raise exception 'Invalid gram quantity'; end if;
  end if;

  if p.current_stock_base < p_quantity_base then raise exception 'Insufficient stock'; end if;

  if p.unit_type = 'piece' then
    total_sale := p_quantity_base * p_selling_price_per_base_unit;
    total_cost := p_quantity_base * p.purchase_price_per_base_unit;
  else
    total_sale := (p_quantity_base/1000) * p_selling_price_per_base_unit;
    total_cost := (p_quantity_base/1000) * p.purchase_price_per_base_unit;
  end if;
  gross := total_sale - total_cost;
  if gross < 0
     and not coalesce((select allow_below_cost_sales from public.shop_settings where id=1),true)
  then
    raise exception 'Below-cost sales are disabled in shop settings';
  end if;

  if p_cash_amount is null and p_upi_amount is null then
    if p_payment_mode='cash' then
      cash_paid := total_sale; upi_paid := 0;
    elsif p_payment_mode='upi' then
      cash_paid := 0; upi_paid := total_sale;
    else
      raise exception 'Split payment requires cash and UPI amounts';
    end if;
  else
    cash_paid := coalesce(p_cash_amount,0);
    upi_paid := coalesce(p_upi_amount,0);
  end if;

  if cash_paid < 0 or upi_paid < 0 or abs((cash_paid + upi_paid) - total_sale) > 0.01 then
    raise exception 'Cash + UPI must equal the sale total';
  end if;

  actual_payment_mode := case
    when cash_paid > 0 and upi_paid > 0 then 'split'
    when upi_paid > 0 then 'upi'
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

  perform set_config('shop.allow_stock_change','on',true);
  update public.products
  set current_stock_base=current_stock_base-p_quantity_base, updated_at=now()
  where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);

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

revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) from public, anon;


create or replace function public.add_inventory_purchase(
  p_product_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_purchase_unit text,
  p_purchase_price numeric
) returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.products; total numeric;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  if p_quantity_base<=0 or p_quantity_display<=0 or p_purchase_price<0 then raise exception 'Invalid purchase'; end if;
  select * into p from public.products where id=p_product_id and is_active=true for update;
  if not found then raise exception 'Product not found'; end if;
  if p.unit_type='piece' then
    if mod(p_quantity_base,1)<>0 or p_purchase_unit<>'piece' or p_quantity_display<>p_quantity_base then raise exception 'Piece purchases must use whole pieces'; end if;
  else
    if p_purchase_unit not in ('grams','kg') then raise exception 'Weight purchases must use grams or kg'; end if;
    if p_purchase_unit='kg' and p_quantity_base<>p_quantity_display*1000 then raise exception 'Invalid kg purchase quantity'; end if;
    if p_purchase_unit='grams' and p_quantity_base<>p_quantity_display then raise exception 'Invalid gram purchase quantity'; end if;
  end if;
  total:=case when p.unit_type='weight' then (p_quantity_base/1000)*p_purchase_price else p_quantity_base*p_purchase_price end;
  insert into public.inventory_purchases(product_id,quantity_base,quantity_display,purchase_unit,purchase_price_per_base_unit,total_cost,purchased_by)
  values(p_product_id,p_quantity_base,p_quantity_display,p_purchase_unit,p_purchase_price,total,(select auth.uid()));
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=current_stock_base+p_quantity_base,purchase_price_per_base_unit=p_purchase_price,updated_at=now() where id=p_product_id;
  perform set_config('shop.allow_stock_change','off',true);
  perform public.write_audit('purchase_added','product',p_product_id,jsonb_build_object('quantity_base',p_quantity_base,'quantity_display',p_quantity_display,'unit',p_purchase_unit,'purchase_price',p_purchase_price,'total_cost',total));
end;
$$;
revoke execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric) from public, anon;
grant execute on function public.add_inventory_purchase(uuid,numeric,numeric,text,numeric) to authenticated;

-- Repair the legacy closing RPC: difference is a generated column and must never be written.
create or replace function public.submit_daily_closing(p_business_date date,p_cash numeric,p_upi numeric,p_closing_id uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare closing_id uuid; expected numeric; current_status public.closing_status; shop_tz text;
begin
  if not (select public.is_active_user()) then raise exception 'Account is inactive'; end if;
  if not exists(select 1 from public.profiles where id=(select auth.uid()) and role='worker' and is_active=true) then raise exception 'Only an active worker can submit a closing'; end if;
  if p_cash<0 or p_upi<0 then raise exception 'Cash and UPI cannot be negative'; end if;
  select timezone into shop_tz from public.shop_settings where id=1;
  select coalesce(sum(s.total_sale),0) into expected from public.sales s
  where s.worker_id=(select auth.uid()) and s.voided=false and (s.sold_at at time zone coalesce(shop_tz,'Asia/Kolkata'))::date=p_business_date;
  if p_closing_id is not null then
    select id,status into closing_id,current_status from public.daily_closings where id=p_closing_id and worker_id=(select auth.uid()) for update;
    if closing_id is null then raise exception 'Closing not found'; end if;
    if current_status in ('approved','locked') then raise exception 'Closing is already finalized'; end if;
    update public.daily_closings set business_date=p_business_date,expected_total=expected,cash_amount=p_cash,upi_amount=p_upi,status='submitted',submitted_at=now() where id=closing_id;
  else
    select id,status into closing_id,current_status from public.daily_closings where worker_id=(select auth.uid()) and business_date=p_business_date for update;
    if closing_id is not null and current_status in ('approved','locked') then raise exception 'Closing is already finalized'; end if;
    if closing_id is null then
      insert into public.daily_closings(worker_id,business_date,expected_total,cash_amount,upi_amount,status,submitted_at)
      values((select auth.uid()),p_business_date,expected,p_cash,p_upi,'submitted',now()) returning id into closing_id;
    else
      update public.daily_closings set expected_total=expected,cash_amount=p_cash,upi_amount=p_upi,status='submitted',submitted_at=now() where id=closing_id;
    end if;
  end if;
  perform public.write_audit('closing_submitted','daily_closing',closing_id,jsonb_build_object('business_date',p_business_date,'expected_total',expected,'cash',p_cash,'upi',p_upi));
  return closing_id;
end;
$$;

-- Day-end RPCs need definer rights because authenticated users intentionally have read-only access to closings.
alter function public.submit_day_end_summary(uuid) security definer;
alter function public.confirm_day_end_summary(uuid) security definer;

do $$ begin alter publication supabase_realtime add table public.inventory_purchases; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.day_end_summary_lines; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.audit_logs; exception when duplicate_object then null; when undefined_object then null; end $$;


-- Direct table updates are only for a worker's own draft. Owner finalization uses protected RPCs.
drop policy if exists "day end update draft" on public.day_end_summaries;
create policy "day end update draft" on public.day_end_summaries for update to authenticated
using (worker_id=(select auth.uid()) and status='draft')
with check ((select public.is_active_user()) and worker_id=(select auth.uid()) and status='draft');

-- Preserve an audit marker when the owner uses Start over. Transaction history is still cleared as requested.
create or replace function public.clear_all_shop_data()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;
  perform public.write_audit('shop_data_cleared','shop',null,jsonb_build_object('cleared_at',now()));
  truncate table public.day_end_summary_lines,public.day_end_summaries,public.daily_closings,public.sales,public.inventory_purchases,public.automatic_day_end_snapshots restart identity;
  perform set_config('shop.allow_stock_change','on',true);
  update public.products set current_stock_base=0,updated_at=now() where id is not null;
  perform set_config('shop.allow_stock_change','off',true);
end;
$$;
revoke execute on function public.clear_all_shop_data() from public, anon;
grant execute on function public.clear_all_shop_data() to authenticated;


create table if not exists public.automatic_day_end_snapshots (
  business_date date primary key,
  total_sales numeric(14,2) not null default 0,
  total_cost numeric(14,2) not null default 0,
  total_profit numeric(14,2) not null default 0,
  transactions integer not null default 0,
  cash_amount numeric(14,2) not null default 0,
  upi_amount numeric(14,2) not null default 0,
  product_breakdown jsonb not null default '[]'::jsonb,
  worker_breakdown jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.automatic_day_end_snapshots enable row level security;
grant select on public.automatic_day_end_snapshots to authenticated;
drop policy if exists "snapshot select" on public.automatic_day_end_snapshots;
create policy "snapshot select" on public.automatic_day_end_snapshots for select to authenticated
using ((select public.is_active_user()));

create or replace function public.refresh_automatic_day_end_snapshot(p_business_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare tz text; product_json jsonb; worker_json jsonb;
begin
  select timezone into tz from public.shop_settings where id=1;
  select coalesce(jsonb_agg(x order by x->>'product'), '[]'::jsonb) into product_json
  from (
    select jsonb_build_object('product',coalesce(p.name,'Unknown'),'quantity_base',sum(s.quantity_base),'revenue',round(sum(s.total_sale),2),'profit',round(sum(s.gross_profit),2)) x
    from public.sales s left join public.products p on p.id=s.product_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(p.name,'Unknown')
  ) q;
  select coalesce(jsonb_agg(x order by x->>'worker'), '[]'::jsonb) into worker_json
  from (
    select jsonb_build_object('worker',coalesce(pr.full_name,'Worker'),'transactions',count(*),'revenue',round(sum(s.total_sale),2),'profit',round(sum(s.gross_profit),2),'cash',round(sum(s.cash_amount),2),'upi',round(sum(s.upi_amount),2)) x
    from public.sales s left join public.profiles pr on pr.id=s.worker_id
    where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
    group by coalesce(pr.full_name,'Worker')
  ) q;
  insert into public.automatic_day_end_snapshots(business_date,total_sales,total_cost,total_profit,transactions,cash_amount,upi_amount,product_breakdown,worker_breakdown,updated_at)
  select p_business_date,coalesce(sum(s.total_sale),0),coalesce(sum(s.total_cost),0),coalesce(sum(s.gross_profit),0),count(*),coalesce(sum(s.cash_amount),0),coalesce(sum(s.upi_amount),0),coalesce(product_json,'[]'::jsonb),coalesce(worker_json,'[]'::jsonb),now()
  from public.sales s where not s.voided and (s.sold_at at time zone coalesce(tz,'Asia/Kolkata'))::date=p_business_date
  on conflict (business_date) do update set total_sales=excluded.total_sales,total_cost=excluded.total_cost,total_profit=excluded.total_profit,transactions=excluded.transactions,cash_amount=excluded.cash_amount,upi_amount=excluded.upi_amount,product_breakdown=excluded.product_breakdown,worker_breakdown=excluded.worker_breakdown,updated_at=now();
end;
$$;
revoke execute on function public.refresh_automatic_day_end_snapshot(date) from public,anon,authenticated;

create or replace function public.refresh_automatic_day_end_snapshot_trigger()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare tz text; d date;
begin
  select timezone into tz from public.shop_settings where id=1;
  d=(coalesce(NEW.sold_at,OLD.sold_at) at time zone coalesce(tz,'Asia/Kolkata'))::date;
  perform public.refresh_automatic_day_end_snapshot(d);
  return NEW;
end;
$$;
revoke execute on function public.refresh_automatic_day_end_snapshot_trigger() from public,anon,authenticated;
drop trigger if exists sales_refresh_automatic_day_end_snapshot on public.sales;
create trigger sales_refresh_automatic_day_end_snapshot after insert or update of voided on public.sales
for each row execute function public.refresh_automatic_day_end_snapshot_trigger();



-- ============================================================
-- SOURCE: supabase/migrations/20260924180000_permanent_product_delete.sql
-- ============================================================
-- Permanent product deletion.
-- Historical sales, purchases and legacy day-end lines keep a product-name snapshot.
-- Their product_id becomes NULL when the product row is deleted, so history is preserved.
-- A later product with the same name is a completely new product.

alter table public.sales
  add column if not exists product_name_snapshot text not null default 'Deleted product';

alter table public.inventory_purchases
  add column if not exists product_name_snapshot text not null default 'Deleted product';

alter table public.day_end_summary_lines
  add column if not exists product_name_snapshot text not null default 'Deleted product';

update public.sales s
set product_name_snapshot = p.name
from public.products p
where s.product_id = p.id
  and (s.product_name_snapshot = 'Deleted product' or s.product_name_snapshot is null);

update public.inventory_purchases i
set product_name_snapshot = p.name
from public.products p
where i.product_id = p.id
  and (i.product_name_snapshot = 'Deleted product' or i.product_name_snapshot is null);

update public.day_end_summary_lines l
set product_name_snapshot = p.name
from public.products p
where l.product_id = p.id
  and (l.product_name_snapshot = 'Deleted product' or l.product_name_snapshot is null);

alter table public.sales alter column product_id drop not null;
alter table public.inventory_purchases alter column product_id drop not null;
alter table public.day_end_summary_lines alter column product_id drop not null;

do $$
declare r record;
begin
  for r in
    select n.nspname as schema_name,
           c.relname as table_name,
           con.conname as constraint_name
    from pg_constraint con
    join pg_class c on c.oid=con.conrelid
    join pg_namespace n on n.oid=c.relnamespace
    join pg_class ref on ref.oid=con.confrelid
    join pg_namespace rn on rn.oid=ref.relnamespace
    where con.contype='f'
      and n.nspname='public'
      and rn.nspname='public'
      and ref.relname='products'
      and c.relname in ('sales','inventory_purchases','day_end_summary_lines')
  loop
    execute format('alter table %I.%I drop constraint %I',
      r.schema_name,r.table_name,r.constraint_name);
  end loop;
end $$;

alter table public.sales
  add constraint sales_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

alter table public.inventory_purchases
  add constraint inventory_purchases_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

alter table public.day_end_summary_lines
  add constraint day_end_summary_lines_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

-- Remove old soft-deleted product rows now that their historical references are safe.
delete from public.products where is_active=false;

create or replace function public.delete_product(p_product_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare p public.products;
begin
  if not (select public.is_owner()) then raise exception 'Owner only'; end if;

  select * into p
  from public.products
  where id=p_product_id
  for update;

  if not found then raise exception 'Product not found'; end if;

  delete from public.products
  where id=p_product_id;
end;
$$;

revoke execute on function public.delete_product(uuid) from public, anon;
grant execute on function public.delete_product(uuid) to authenticated;

-- Product deletion is available only through the protected owner RPC.
revoke delete on public.products from authenticated;


-- ============================================================
-- SOURCE: supabase/migrations/20260924190000_dashboard_reset_reports.sql
-- ============================================================
-- Dashboard reset time and business-day reporting support.
-- Existing installations: apply this migration after the current schema/migrations.

alter table public.shop_settings
  add column if not exists dashboard_reset_time text not null default '00:00';

do $$
begin
  alter table public.shop_settings
    add constraint shop_settings_dashboard_reset_time_check
    check (dashboard_reset_time ~ '^[0-2][0-9]:[0-5][0-9]$' and dashboard_reset_time < '24:00');
exception when duplicate_object then null;
end $$;

update public.shop_settings
set dashboard_reset_time='00:00'
where dashboard_reset_time is null or dashboard_reset_time !~ '^[0-2][0-9]:[0-5][0-9]$' or dashboard_reset_time >= '24:00';

comment on column public.shop_settings.dashboard_reset_time is
  'Local shop time at which the current business-day dashboard period resets; reports retain prior business days.';


-- ============================================================
-- FINAL COMPATIBILITY FIX
-- ============================================================
-- The current app uses the 9-argument record_sale RPC. This wrapper
-- preserves compatibility with any older client still calling the
-- original 6-argument RPC, which caused:
-- ERROR 42883: function public.record_sale(uuid, uuid, numeric,
-- numeric, text, numeric) does not exist
--
-- Six-argument calls are treated as CASH sales.
drop function if exists public.record_sale(uuid,uuid,numeric,numeric,text,numeric);

create or replace function public.record_sale(
  p_product_id uuid,
  p_worker_id uuid,
  p_quantity_base numeric,
  p_quantity_display numeric,
  p_sold_unit text,
  p_selling_price_per_base_unit numeric
) returns public.sales
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return public.record_sale(
    p_product_id,
    p_worker_id,
    p_quantity_base,
    p_quantity_display,
    p_sold_unit,
    p_selling_price_per_base_unit,
    'cash',
    null,
    null
  );
end;
$$;

revoke execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric) from public, anon;
grant execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric) to authenticated;

-- Ensure the current 9-argument RPC is available to the app.
grant execute on function public.record_sale(uuid,uuid,numeric,numeric,text,numeric,text,numeric,numeric) to authenticated;

-- ============================================================
-- FINAL BUSINESS-DAY RESET CONSISTENCY PATCH
-- ============================================================
-- Dashboard reset time is stored in shop_settings as HH24:MI.
-- Keep the persisted automatic snapshot aligned with that business day.
create or replace function public.refresh_automatic_day_end_snapshot(p_business_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tz text;
  reset_time text;
  product_json jsonb;
  worker_json jsonb;
  start_utc timestamptz;
  end_utc timestamptz;
begin
  select timezone, dashboard_reset_time
    into tz, reset_time
  from public.shop_settings
  where id=1;

  reset_time := coalesce(reset_time,'00:00');
  start_utc := (
    p_business_date::text || ' ' || reset_time
  )::timestamp at time zone coalesce(tz,'Asia/Kolkata');
  end_utc := (
    (p_business_date + 1)::text || ' ' || reset_time
  )::timestamp at time zone coalesce(tz,'Asia/Kolkata');

  select coalesce(jsonb_agg(x order by x->>'product'),'[]'::jsonb)
  into product_json
  from (
    select jsonb_build_object(
      'product',coalesce(p.name,'Unknown'),
      'quantity_base',sum(s.quantity_base),
      'revenue',round(sum(s.total_sale),2),
      'profit',round(sum(s.gross_profit),2)
    ) x
    from public.sales s
    left join public.products p on p.id=s.product_id
    where not s.voided
      and s.sold_at >= start_utc
      and s.sold_at < end_utc
    group by coalesce(p.name,'Unknown')
  ) q;

  select coalesce(jsonb_agg(x order by x->>'worker'),'[]'::jsonb)
  into worker_json
  from (
    select jsonb_build_object(
      'worker',coalesce(pr.full_name,'Worker'),
      'transactions',count(*),
      'revenue',round(sum(s.total_sale),2),
      'profit',round(sum(s.gross_profit),2),
      'cash',round(sum(s.cash_amount),2),
      'upi',round(sum(s.upi_amount),2)
    ) x
    from public.sales s
    left join public.profiles pr on pr.id=s.worker_id
    where not s.voided
      and s.sold_at >= start_utc
      and s.sold_at < end_utc
    group by coalesce(pr.full_name,'Worker')
  ) q;

  insert into public.automatic_day_end_snapshots(
    business_date,total_sales,total_cost,total_profit,transactions,
    cash_amount,upi_amount,product_breakdown,worker_breakdown,updated_at
  )
  select
    p_business_date,
    coalesce(sum(s.total_sale),0),
    coalesce(sum(s.total_cost),0),
    coalesce(sum(s.gross_profit),0),
    count(*),
    coalesce(sum(s.cash_amount),0),
    coalesce(sum(s.upi_amount),0),
    coalesce(product_json,'[]'::jsonb),
    coalesce(worker_json,'[]'::jsonb),
    now()
  from public.sales s
  where not s.voided
    and s.sold_at >= start_utc
    and s.sold_at < end_utc
  on conflict (business_date) do update set
    total_sales=excluded.total_sales,
    total_cost=excluded.total_cost,
    total_profit=excluded.total_profit,
    transactions=excluded.transactions,
    cash_amount=excluded.cash_amount,
    upi_amount=excluded.upi_amount,
    product_breakdown=excluded.product_breakdown,
    worker_breakdown=excluded.worker_breakdown,
    updated_at=now();
end;
$$;

revoke execute on function public.refresh_automatic_day_end_snapshot(date) from public,anon,authenticated;

-- Rebuild today's snapshot immediately using the configured business-day
-- definition, if the helper/table already exists.
do $$
declare d date;
begin
  if to_regclass('public.automatic_day_end_snapshots') is not null
     and to_regclass('public.shop_settings') is not null
  then
    select (
      case
        when localtime < (coalesce(dashboard_reset_time,'00:00')::time)
        then (current_date - 1)
        else current_date
      end
    )
    into d
    from public.shop_settings
    where id=1;

    if d is not null then
      perform public.refresh_automatic_day_end_snapshot(d);
    end if;
  end if;
end $$;

-- ============================================================
-- IMPORTANT
-- ============================================================
-- This file is intended to be run in Supabase SQL Editor against
-- an existing Shop Management database. It consolidates the
-- currently implemented database migrations and adds the legacy
-- 6-argument record_sale compatibility wrapper.
