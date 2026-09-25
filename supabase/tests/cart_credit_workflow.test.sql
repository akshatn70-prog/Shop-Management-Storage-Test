begin;

select plan(8);

select has_table('public', 'sale_transactions', 'sale_transactions table exists');
select has_table('public', 'creditors', 'creditors table exists');
select has_table('public', 'credit_ledger', 'credit_ledger table exists');

select has_column('public', 'shop_settings', 'workers_can_modify_selling_price', 'worker price permission exists');
select has_column('public', 'sales', 'transaction_id', 'sales transaction grouping exists');

select has_function('public', 'complete_cart_sale', ARRAY['uuid','jsonb','text','numeric','numeric','uuid'], 'complete_cart_sale RPC exists');
select has_function('public', 'receive_credit_payment', ARRAY['uuid','numeric','text','numeric','numeric'], 'receive_credit_payment RPC exists');
select has_function('public', 'get_or_create_creditor', ARRAY['text','text'], 'creditor creation RPC exists');

select * from finish();
rollback;
