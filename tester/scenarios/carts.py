from __future__ import annotations

from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts


def _item_total(product, qty: float, unit: str) -> tuple[float, float]:
    base = qty if product.unit == "piece" else (qty * 1000 if unit == "kg" else qty)
    if product.unit == "piece":
        return base, qty * product.selling_price
    price_per_base = product.selling_price / 1000 if product.price_unit == "kg" else product.selling_price
    return base, base * price_per_base


async def add_cart_item(ctx: ScenarioContext, key: str, qty: float, unit: str) -> tuple[str, float]:
    product = ctx.run.products[key]
    await ctx.go("cart")
    form = ctx.page.locator("#cartAdd")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", qty)
    await ctx.form_select(form, "unit", unit)
    await ctx.session.click(form.get_by_role("button", name="Add to Cart", exact=True))
    feedback = await ctx.wait_success("Added to cart")
    base, amount = _item_total(product, qty, unit)
    return feedback, amount


async def sell_cart(
    ctx: ScenarioContext, mode: str, pair_index: int | None = None, account_index: int = 0
) -> str:
    await ensure_accounts(ctx)
    creditor = ctx.run.creditors[account_index % len(ctx.run.creditors)] if ctx.run.creditors else ctx.run.creditor
    creditor_balance_before = None
    if mode in ("credit", "credit_split") and creditor:
        creditor_balance_before = await account_balance(ctx, "creditor", creditor)
    await ctx.go("history")
    before_actions = await ctx.page.locator(".void-sale[data-transaction-id]").count()
    await ctx.go("cart")
    keys = ("Piece", "Weight-Kg") if pair_index is None else (
        f"Cart-{pair_index * 2 + 1:02d}", f"Cart-{pair_index * 2 + 2:02d}"
    )
    items = []
    for key in keys:
        product = ctx.run.products[key]
        qty, unit = (1, "piece") if product.unit == "piece" else (
            (1, "kg") if product.price_unit == "kg" else (1000, "grams")
        )
        _, amount = await add_cart_item(ctx, key, qty, unit)
        base, _ = _item_total(product, qty, unit)
        items.append((key, product, qty, unit, base, amount))
    total = sum(item[5] for item in items)
    if abs(total - 1000) > 0.01:
        raise AssertionError("Mixed-unit cart total calculation did not match the expected total.")

    await ctx.go("stock")
    before = {key: await ctx.stock(product.name) for key, product, *_ in items}
    await ctx.go("cart")
    payment = ctx.page.locator("#cartPay")
    await ctx.form_select(payment, "mode", mode)
    cash = upi = credit = 0.0
    if mode == "cash":
        cash = total
    elif mode == "upi":
        upi = total
    elif mode == "split":
        cash = round(total / 2, 2)
        upi = round(total - cash, 2)
        await ctx.form_fill(payment, "cash", cash)
        await ctx.form_fill(payment, "upi", upi)
    elif mode == "credit":
        credit = total
        await ctx.form_fill(payment, "credit", credit)
        await ctx.select_option_containing(await ctx.field(payment, "creditor"), creditor.name)
    elif mode == "credit_split":
        cash = round(total * 0.25, 2)
        upi = round(total * 0.25, 2)
        credit = round(total - cash - upi, 2)
        await ctx.form_fill(payment, "cash", cash)
        await ctx.form_fill(payment, "upi", upi)
        await ctx.form_fill(payment, "credit", credit)
        await ctx.select_option_containing(await ctx.field(payment, "creditor"), creditor.name)
    await ctx.session.click(payment.get_by_role("button", name="Confirm Cart Sale", exact=True))
    feedback = await ctx.wait_success("Cart sale completed")
    await ctx.page.locator(".page-head .badge").get_by_text("0 item(s)", exact=True).wait_for(timeout=15_000)
    await ctx.go("stock")
    after = {}
    for key, product, _, _, base, _ in items:
        after[key] = await ctx.wait_stock_value(product.name, before[key] - base)
        ctx.run.products[key].stock_base = after[key]
    if credit > 0 and creditor and creditor_balance_before is not None:
        creditor_balance_after = await account_balance(ctx, "creditor", creditor)
        if abs(creditor_balance_after - creditor_balance_before - credit) > 0.01:
            raise AssertionError(
                f"Creditor balance should rise by cart credit ₹{credit:.2f}; found {creditor_balance_before:.2f} → {creditor_balance_after:.2f}."
            )
        creditor.balance = creditor_balance_after
    ctx.run.last_cart = {
        "mode": mode, "total": total, "cash": cash, "upi": upi, "credit": credit,
        "products": [item[1].name for item in items],
    }
    if ctx.run.benchmark_active:
        ctx.run.activity["cart_sales"] = ctx.run.activity.get("cart_sales", 0) + 1
    await ctx.go("history")
    after_actions = await ctx.page.locator(".void-sale[data-transaction-id]").count()
    if after_actions != before_actions + 1:
        raise AssertionError(
            f"Expected exactly one new cart transaction action; found {before_actions} → {after_actions}."
        )
    return (
        f"Mixed cart total ₹{total:.2f} = cash ₹{cash:.2f} + UPI ₹{upi:.2f} + "
        f"credit ₹{credit:.2f}; stock verified; one transaction action; feedback: {feedback}"
    )


async def edit_cart_item(ctx: ScenarioContext) -> str:
    piece = ctx.run.products["Piece"]
    await ctx.go("cart")
    await add_cart_item(ctx, "Piece", 1, "piece")
    item_row = ctx.page.get_by_role("row").filter(has_text=piece.name)
    ctx.session.queue_prompts("2", "32")
    await ctx.session.click(item_row.get_by_role("button", name="Edit", exact=True))
    await ctx.go("cart")
    row = ctx.page.get_by_role("row").filter(has_text=piece.name)
    text = await row.inner_text()
    if "2" not in text or "32" not in text:
        raise AssertionError(f"Edited cart quantity/amount not reflected: {text}")
    total_notice = await ctx.page.locator(".panel").get_by_text("Cart total:", exact=False).last.inner_text()
    if "32" not in total_notice:
        raise AssertionError(f"Cart preview total did not update: {total_notice}")
    await ctx.session.click(row.get_by_role("button", name="Delete", exact=True))
    return f"Edited row: {text.strip()}; {total_notice.strip()}; draft removed."


async def run(ctx: ScenarioContext) -> None:
    await ctx.step(
        "Carts: edit an item and verify preview",
        "Quantity, item amount, and cart total update after editing.",
        lambda: edit_cart_item(ctx),
    )
    for index, mode in enumerate(("cash", "upi", "split", "credit", "credit_split")):
        await ctx.step(
            f"Carts: mixed-item {mode} payment",
            "Two products complete as one cart transaction; payment parts sum to total and both stocks decrease.",
            lambda mode=mode, index=index: sell_cart(ctx, mode, index, index),
        )

async def invalid_split_payment(ctx: ScenarioContext) -> str:
    piece = ctx.run.products["Piece"]
    weight = ctx.run.products["Weight-Kg"]
    await ctx.go("stock")
    piece_before = await ctx.stock(piece.name)
    weight_before = await ctx.stock(weight.name)
    await add_cart_item(ctx, "Piece", 1, "piece")
    await add_cart_item(ctx, "Weight-Kg", 100, "grams")
    total = _item_total(piece, 1, "piece")[1] + _item_total(weight, 100, "grams")[1]
    await ctx.go("cart")
    form = ctx.page.locator("#cartPay")
    await ctx.form_select(form, "mode", "split")
    await ctx.form_fill(form, "cash", total)
    await ctx.form_fill(form, "upi", 1)
    await ctx.session.click(form.get_by_role("button", name="Confirm Cart Sale", exact=True))
    message = await ctx.wait_toast("error", timeout_ms=3_000)
    if not message or "equal" not in message.casefold():
        raise AssertionError(f"Invalid cart split was not rejected; found {message!r}.")
    await ctx.go("stock")
    if await ctx.stock(piece.name) != piece_before or await ctx.stock(weight.name) != weight_before:
        raise AssertionError("Rejected cart payment changed product stock.")
    await ctx.go("cart")
    for name in (piece.name, weight.name):
        row = ctx.page.get_by_role("row").filter(has_text=name)
        if await row.count():
            await ctx.session.click(row.get_by_role("button", name="Delete", exact=True))
            await ctx.go("cart")
    return f"Rejected invalid split with “{message}”; both stocks unchanged; cart cleared."


async def invalid_split_suite(ctx: ScenarioContext) -> None:
    await ctx.step(
        "Carts: reject invalid split payment total",
        "Cash + UPI must equal the mixed-item cart total; invalid payment leaves stock unchanged.",
        lambda: invalid_split_payment(ctx),
    )
