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
