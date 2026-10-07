-- Migration 027: repair the debtor credit-purchase trigger.
-- Migration 025 is intentionally left unchanged.
-- This replaces only the already-installed trigger function that can run
-- after a credit purchase is inserted.

create or replace function public.create_debtor_credit_purchase_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop_id text;
begin
  if coalesce(new.pre_stock,false)=false
     and coalesce(new.credit_amount,0) > 0.01
     and new.debtor_id is not null
  then
    v_shop_id := (
      select pr.shop_id
      from public.profiles pr
      where pr.id=new.purchased_by
        and pr.is_active=true
    );

    if v_shop_id is null or btrim(v_shop_id)='' then
      raise exception 'Shop ID is not configured';
    end if;

    if not exists (
      select 1
      from public.debtors d
      where d.id=new.debtor_id
        and d.shop_id=v_shop_id
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
      v_shop_id,
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

revoke all on function public.create_debtor_credit_purchase_ledger()
from public, anon;

grant execute on function public.create_debtor_credit_purchase_ledger()
to authenticated;

drop trigger if exists create_debtor_credit_purchase_ledger
on public.inventory_purchases;

create trigger create_debtor_credit_purchase_ledger
after insert on public.inventory_purchases
for each row
execute function public.create_debtor_credit_purchase_ledger();

insert into public.shop_management_schema_version(version)
values (27)
on conflict (version) do nothing;

select pg_notify('pgrst','reload schema');