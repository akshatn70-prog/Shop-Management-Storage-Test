from __future__ import annotations

from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts


def expected_total(product, qty: float, unit: str = "piece") -> float:
    if product.unit == "piece":
        return qty * product.selling_price
    base = qty * 1000 if unit == "kg" else qty
    price_per_base = product.selling_price / 1000 if product.price_unit == "kg" else product.selling_price
    return base * price_per_base


async def sell_product(
    ctx: ScenarioContext, key: str, mode: str, qty: float, unit: str, account_index: int = 0
) -> str:
    product = ctx.run.products[key]
    await ensure_accounts(ctx)
    creditor = ctx.run.creditors[account_index % len(ctx.run.creditors)] if ctx.run.creditors else ctx.run.creditor
    creditor_balance_before = None
    if mode in ("credit", "credit_split") and creditor:
        creditor_balance_before = await account_balance(ctx, "creditor", creditor)
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.go("sale")
    form = ctx.page.locator("#saleForm")
    await form.wait_for(state="visible")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", qty)
    if product.unit != "piece":
        unit_select = await ctx.field(form, "unit")
        if not await unit_select.is_enabled():
            await ctx.page.wait_for_function(
                "() => !document.querySelector('#saleForm select[name=unit]')?.disabled",
                timeout=5_000,
            )
        await ctx.form_select(form, "unit", unit)
    total = expected_total(product, qty, unit)
    await ctx.form_fill(form, "price", product.selling_price)
    await ctx.form_select(form, "mode", mode)
    base = qty if product.unit == "piece" else (qty * 1000 if unit == "kg" else qty)
    cash = upi = credit = 0.0
    if mode == "cash":
        cash = total
    elif mode == "upi":
        upi = total
    elif mode == "split":
        cash = round(total / 2, 2)
        upi = round(total - cash, 2)
        await ctx.form_fill(form, "cash", cash)
        await ctx.form_fill(form, "upi", upi)
    elif mode == "credit":
        credit = total
        await ctx.select_option_containing(await ctx.field(form, "creditor"), creditor.name)
    elif mode == "credit_split":
        cash = round(total * 0.25, 2)
        upi = round(total * 0.25, 2)
        credit = round(total - cash - upi, 2)
        await ctx.form_fill(form, "cash", cash)
        await ctx.form_fill(form, "upi", upi)
        await ctx.form_fill(form, "credit", credit)
        await ctx.select_option_containing(await ctx.field(form, "creditor"), creditor.name)
    await ctx.session.click(form.get_by_role("button", name="Complete Sale", exact=True))
    feedback = await ctx.wait_success("Sale completed")
    await ctx.go("stock")
    after = await ctx.wait_stock_value(product.name, before - base)
    if abs(after - (before - base)) > 0.001:
        raise AssertionError(f"Sale should reduce stock from {before} to {before - base}; found {after}.")
    product.stock_base = after
    if credit > 0 and creditor and creditor_balance_before is not None:
        creditor_balance_after = await account_balance(ctx, "creditor", creditor)
        if abs(creditor_balance_after - creditor_balance_before - credit) > 0.01:
            raise AssertionError(
                f"Creditor balance should rise by ₹{credit:.2f}; found {creditor_balance_before:.2f} → {creditor_balance_after:.2f}."
            )
        creditor.balance = creditor_balance_after
    ctx.run.last_sale = {
        "product": product.name, "mode": mode, "total": total, "cash": cash,
        "upi": upi, "credit": credit, "stock_before": before, "stock_after": after,
    }
    if ctx.run.benchmark_active:
        ctx.run.activity["single_sales"] = ctx.run.activity.get("single_sales", 0) + 1
    return (
        f"Stock {before} → {after}; total ₹{total:.2f} = cash ₹{cash:.2f} + "
        f"UPI ₹{upi:.2f} + credit ₹{credit:.2f}; feedback: {feedback}"
    )


async def sell_one(ctx: ScenarioContext, mode: str, qty: float = 1, account_index: int = 0) -> str:
    return await sell_product(ctx, "Piece", mode, qty, "piece", account_index)


async def insufficient_stock(ctx: ScenarioContext) -> str:
    product = ctx.run.products["Piece"]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.go("sale")
    form = ctx.page.locator("#saleForm")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", before + 1000)
    await ctx.session.click(form.get_by_role("button", name="Complete Sale", exact=True))
    message = await ctx.wait_toast("error", timeout_ms=4_000)
    if not message or "stock" not in message.casefold():
        raise AssertionError(f"Expected a clear insufficient-stock error; found {message!r}.")
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if after != before:
        raise AssertionError(f"Rejected sale changed stock: {before} → {after}.")
    return f"Rejected with “{message}”; stock remained {after}."


async def invalid_piece_fraction(ctx: ScenarioContext) -> str:
    product = ctx.run.products["Piece"]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.go("sale")
    form = ctx.page.locator("#saleForm")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", "0.5")
    await ctx.session.click(form.get_by_role("button", name="Complete Sale", exact=True))
    message = await ctx.wait_toast("error", timeout_ms=4_000)
    if not message or not any(word in message.casefold() for word in ("piece", "whole", "quantity")):
        raise AssertionError(f"Fractional pieces should be rejected clearly; found {message!r}.")
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if after != before:
        raise AssertionError(f"Rejected fractional sale changed stock: {before} → {after}.")
    return f"Fractional sale rejected with “{message}”; stock remained {after}."


async def invalid_payment_parts(ctx: ScenarioContext, mode: str) -> str:
    product = ctx.run.products["Piece"]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.go("sale")
    form = ctx.page.locator("#saleForm")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", 1)
    await ctx.form_fill(form, "price", product.selling_price)
    await ctx.form_select(form, "mode", mode)
    await ctx.form_fill(form, "cash", 1)
    await ctx.form_fill(form, "upi", 1)
    if mode == "credit_split":
        await ctx.form_fill(form, "credit", 1)
        await ctx.select_option_containing(await ctx.field(form, "creditor"), ctx.run.creditor.name)
    await ctx.session.click(form.get_by_role("button", name="Complete Sale", exact=True))
    message = await ctx.wait_toast("error", timeout_ms=3_000)
    if not message or not any(word in message.casefold() for word in ("equal", "total", "credit")):
        raise AssertionError(f"Invalid {mode} payment sum was not rejected; found {message!r}.")
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if after != before:
        raise AssertionError(f"Rejected {mode} sale changed stock: {before} → {after}.")
    return f"Rejected with “{message}”; stock remained {after}."


async def run(ctx: ScenarioContext) -> None:
    await ensure_accounts(ctx)
    modes = ("cash", "upi", "split", "credit", "credit_split")
    for index, key in enumerate(list(ctx.run.products)[:40]):
        mode = modes[index % len(modes)]
        product = ctx.run.products[key]
        unit = "piece" if product.unit == "piece" else ("kg" if product.price_unit == "kg" else "grams")
        reference_units = 2 if index < 3 else 1
        qty = reference_units * (1000 if unit == "grams" else 1)
        await ctx.step(
            f"Sales: {key} by {mode}",
            "Single-item sale saves, stock changes by the right unit amount, and payment parts equal its total.",
            lambda key=key, mode=mode, qty=qty, unit=unit, index=index: sell_product(
                ctx, key, mode, qty, unit, (index // 5) % 5
            ),
        )
    await ctx.step(
        "Sales: reject insufficient stock",
        "A too-large sale shows a clear error and leaves stock unchanged.",
        lambda: insufficient_stock(ctx),
    )
    await ctx.step(
        "Sales: reject fractional piece quantity",
        "A piece item rejects fractions and leaves stock unchanged.",
        lambda: invalid_piece_fraction(ctx),
    )
    await ctx.step(
        "Sales: reject invalid split total",
        "Cash + UPI must equal the total; invalid payment does not change stock.",
        lambda: invalid_payment_parts(ctx, "split"),
    )
    await ctx.step(
        "Sales: reject invalid credit-split total",
        "Cash + UPI + credit must equal the total; invalid payment does not change stock.",
        lambda: invalid_payment_parts(ctx, "credit_split"),
    )
