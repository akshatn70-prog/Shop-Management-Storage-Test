-- Repair historical product-name snapshots where the product still exists.
-- Permanently deleted products keep their historical snapshot as-is.
update public.sales s
set product_name_snapshot=p.name
from public.products p
where s.product_id=p.id
  and lower(btrim(coalesce(s.product_name_snapshot,'')))='deleted product';

update public.inventory_purchases i
set product_name_snapshot=p.name
from public.products p
where i.product_id=p.id
  and lower(btrim(coalesce(i.product_name_snapshot,'')))='deleted product';

update public.returns r
set product_name_snapshot=p.name
from public.products p
where r.product_id=p.id
  and lower(btrim(coalesce(r.product_name_snapshot,'')))='deleted product';

