-- Safe debtor / creditor account deletion.
-- Migration 024: account soft-delete only; all historical ledger/transaction rows remain intact.
-- Debtor = supplier account (purchase on credit).
-- Creditor = customer account (sale on credit).

create or replace function public.delete_creditor_account(p_creditor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop text;
  v_balance numeric;
  v_exists boolean;
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  v_shop := (select shop_id from public.profiles where id = (select auth.uid()));
  if v_shop is null then
    raise exception 'Shop ID is not configured';
  end if;

  select exists(
    select 1
    from public.creditors
    where id = p_creditor_id
      and shop_id = v_shop
      and is_active = true
  ) into v_exists;

  if not v_exists then
    raise exception 'Creditor not found or already deleted';
  end if;

  select coalesce(sum(
    case
      when type = 'credit_sale' then amount
      when type = 'payment_received' then -amount
      else amount
    end
  ), 0)
  into v_balance
  from public.credit_ledger
  where creditor_id = p_creditor_id
    and shop_id = v_shop;

  -- A non-zero balance includes an overpayment/credit in either direction.
  if abs(v_balance) > 0.01 then
    raise exception 'Cannot delete creditor with non-zero balance of %', round(v_balance, 2);
  end if;

  update public.creditors
  set is_active = false,
      updated_at = now()
  where id = p_creditor_id
    and shop_id = v_shop
    and is_active = true;

  perform public.write_audit(
    'creditor_account_deleted',
    'creditor',
    p_creditor_id,
    jsonb_build_object(
      'previous_balance', round(v_balance, 2),
      'account_preserved', true,
      'deleted_as', 'inactive'
    )
  );
end;
$$;

revoke all on function public.delete_creditor_account(uuid) from public, anon;
grant execute on function public.delete_creditor_account(uuid) to authenticated;

create or replace function public.delete_debtor_account(p_debtor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shop text;
  v_balance numeric;
  v_exists boolean;
begin
  if not (select public.is_owner()) then
    raise exception 'Owner only';
  end if;

  v_shop := (select shop_id from public.profiles where id = (select auth.uid()));
  if v_shop is null then
    raise exception 'Shop ID is not configured';
  end if;

  select exists(
    select 1
    from public.debtors
    where id = p_debtor_id
      and shop_id = v_shop
      and is_active = true
  ) into v_exists;

  if not v_exists then
    raise exception 'Debtor not found or already deleted';
  end if;

  select coalesce(sum(
    case
      when type in ('credit_purchase', 'adjustment') then amount
      when type = 'payment_made' then -amount
      else 0
    end
  ), 0)
  into v_balance
  from public.debtor_ledger
  where debtor_id = p_debtor_id
    and shop_id = v_shop;

  -- A non-zero balance includes an overpayment/credit in either direction.
  if abs(v_balance) > 0.01 then
    raise exception 'Cannot delete debtor with non-zero balance of %', round(v_balance, 2);
  end if;

  update public.debtors
  set is_active = false,
      updated_at = now()
  where id = p_debtor_id
    and shop_id = v_shop
    and is_active = true;

  perform public.write_audit(
    'debtor_account_deleted',
    'debtor',
    p_debtor_id,
    jsonb_build_object(
      'previous_balance', round(v_balance, 2),
      'account_preserved', true,
      'deleted_as', 'inactive'
    )
  );
end;
$$;

revoke all on function public.delete_debtor_account(uuid) from public, anon;
grant execute on function public.delete_debtor_account(uuid) to authenticated;

insert into public.shop_management_schema_version(version)
values (24)
on conflict (version) do nothing;

select pg_notify('pgrst', 'reload schema');
