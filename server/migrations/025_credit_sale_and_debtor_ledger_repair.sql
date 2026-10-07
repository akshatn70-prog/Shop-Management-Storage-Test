-- Migration 025: repair credit transaction persistence and debtor balances.
-- Fixes two compatibility issues on databases that already have the credit
-- amount integrity constraints:
--   1. Credit sales must persist sale_transactions.credit_amount and
--      sales.credit_amount.
--   2. Credit purchases must create the corresponding debtor_ledger entry.
--
-- Historical rows are preserved. Existing missing debtor credit entries are
-- backfilled once, without duplicating existing ledger rows.

-- ============================================================
-- 1. Ensure credit_amount exists on both sale tables.
-- ============================================================

alter table public.sale_transactions
  add column if not exists credit_amount numeric(14,2) not null default 0;

alter table public.sales
  add column if not exists credit_amount numeric(14,2) not null default 0;

-- ============================================================
-- 2. Normalize/backfill the persisted credit component.
-- ============================================================

update public.sale_transactions st
set credit_amount = case
  when st.payment_mode='credit' then round(st.total,2)
  when st.payment_mode='credit_split'
    then round(greatest(st.total-st.cash_amount-st.upi_amount,0),2)
  else 0
end
where st.credit_amount is distinct from case
  when st.payment_mode='credit' then round(st.total,2)
  when st.payment_mode='credit_split'
    then round(greatest(st.total-st.cash_amount-st.upi_amount,0),2)
  else 0
end;

update public.sales s
set credit_amount = case
  when s.payment_mode='credit' then round(s.total_sale,2)
  when s.payment_mode='credit_split'
    then round(greatest(s.total_sale-s.cash_amount-s.upi_amount,0),2)
  else 0
end
where s.credit_amount is distinct from case
  when s.payment_mode='credit' then round(s.total_sale,2)
  when s.payment_mode='credit_split'
    then round(greatest(s.total_sale-s.cash_amount-s.upi_amount,0),2)
  else 0
end;

-- ============================================================
-- 3. Keep credit_amount automatically synchronized for new sales.
-- ============================================================

create or replace function public.sync_sale_transaction_credit_amount()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.credit_amount := case
    when new.payment_mode='credit' then round(new.total,2)
    when new.payment_mode='credit_split'
      then round(greatest(new.total-new.cash_amount-new.upi_amount,0),2)
    else 0
  end;
  return new;
end;
$$;

revoke all on function public.sync_sale_transaction_credit_amount() from public, anon;
grant execute on function public.sync_sale_transaction_credit_amount() to authenticated;

drop trigger if exists sync_sale_transaction_credit_amount on public.sale_transactions;
create trigger sync_sale_transaction_credit_amount
before insert or update of total,payment_mode,cash_amount,upi_amount
on public.sale_transactions
for each row
execute function public.sync_sale_transaction_credit_amount();


create or replace function public.sync_sale_credit_amount()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.credit_amount := case
    when new.payment_mode='credit' then round(new.total_sale,2)
    when new.payment_mode='credit_split'
      then round(greatest(new.total_sale-new.cash_amount-new.upi_amount,0),2)
    else 0
  end;
  return new;
end;
$$;

revoke all on function public.sync_sale_credit_amount() from public, anon;
grant execute on function public.sync_sale_credit_amount() to authenticated;

drop trigger if exists sync_sale_credit_amount on public.sales;
create trigger sync_sale_credit_amount
before insert or update of total_sale,payment_mode,cash_amount,upi_amount
on public.sales
for each row
execute function public.sync_sale_credit_amount();

-- ============================================================
-- 4. Normalize the sale amount constraints to the credit-aware form.
-- ============================================================

alter table public.sales
  drop constraint if exists sales_payment_split_check;

alter table public.sales
  add constraint sales_payment_split_check
  check (
    total_sale >= 0
    and cash_amount >= 0
    and upi_amount >= 0
    and credit_amount >= 0
    and (
      (payment_mode='credit'
        and cash_amount=0
        and upi_amount=0
        and abs(credit_amount-total_sale) <= 0.01)
      or
      (payment_mode='credit_split'
        and (cash_amount + upi_amount) > 0
        and credit_amount > 0
        and abs((cash_amount + upi_amount + credit_amount)-total_sale) <= 0.01)
      or
      (payment_mode in ('cash','upi','split')
        and credit_amount=0
        and abs((cash_amount + upi_amount)-total_sale) <= 0.01)
    )
  );

alter table public.sale_transactions
  drop constraint if exists sale_transactions_amounts_check;

alter table public.sale_transactions
  add constraint sale_transactions_amounts_check
  check (
    subtotal >= 0
    and total >= 0
    and cash_amount >= 0
    and upi_amount >= 0
    and credit_amount >= 0
    and (
      (payment_mode='credit'
        and cash_amount=0
        and upi_amount=0
        and abs(credit_amount-total) <= 0.01)
      or
      (payment_mode='credit_split'
        and (cash_amount + upi_amount) > 0
        and credit_amount > 0
        and abs((cash_amount + upi_amount + credit_amount)-total) <= 0.01)
      or
      (payment_mode in ('cash','upi','split')
        and credit_amount=0
        and abs((cash_amount + upi_amount)-total) <= 0.01)
    )
  );

-- ============================================================
-- 5. Create debtor ledger entry automatically for every credit purchase.
-- ============================================================

create or replace function public.create_debtor_credit_purchase_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.pre_stock,false)=false
     and coalesce(new.credit_amount,0) > 0.01
     and new.debtor_id is not null
  then
    if not exists (
      select 1
      from public.debtors d
      where d.id=new.debtor_id
        and d.shop_id=new.shop_id
        and d.is_active=true
    ) then
      raise exception 'Debtor not found for this shop';
    end if;

    insert into public.debtor_ledger(
      shop_id,
      debtor_id,
      purchase_id,
      type,
      amount,
      payment_mode,
      cash_amount,
      upi_amount,
      worker_id,
      notes
    )
    values(
      new.shop_id,
      new.debtor_id,
      new.id,
      'credit_purchase',
      round(new.credit_amount,2),
      'credit',
      0,
      0,
      new.purchased_by,
      'Credit purchase'
    )
    on conflict do nothing;
  end if;

  return new;
end;
$$;

revoke all on function public.create_debtor_credit_purchase_ledger() from public, anon;
grant execute on function public.create_debtor_credit_purchase_ledger() to authenticated;

drop trigger if exists create_debtor_credit_purchase_ledger on public.inventory_purchases;
create trigger create_debtor_credit_purchase_ledger
after insert on public.inventory_purchases
for each row
execute function public.create_debtor_credit_purchase_ledger();

-- Prevent duplicate credit-purchase ledger rows for the same purchase.
create unique index if not exists debtor_ledger_credit_purchase_purchase_uidx
on public.debtor_ledger(purchase_id)
where purchase_id is not null and type='credit_purchase';

-- ============================================================
-- 6. Backfill credit-purchase ledger entries missing from older databases.
-- ============================================================

insert into public.debtor_ledger(
  shop_id,
  debtor_id,
  purchase_id,
  type,
  amount,
  payment_mode,
  cash_amount,
  upi_amount,
  worker_id,
  notes,
  created_at
)
select
  i.shop_id,
  i.debtor_id,
  i.id,
  'credit_purchase',
  round(i.credit_amount,2),
  'credit',
  0,
  0,
  i.purchased_by,
  'Credit purchase (backfilled by migration 025)',
  i.purchased_at
from public.inventory_purchases i
where coalesce(i.pre_stock,false)=false
  and coalesce(i.credit_amount,0) > 0.01
  and i.debtor_id is not null
  and not exists (
    select 1
    from public.debtor_ledger dl
    where dl.purchase_id=i.id
      and dl.type='credit_purchase'
  );

insert into public.shop_management_schema_version(version)
values (25)
on conflict (version) do nothing;

select pg_notify('pgrst','reload schema');
