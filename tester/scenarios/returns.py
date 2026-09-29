from __future__ import annotations

from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts


async def make_return(ctx: ScenarioContext, kind: str, mode: str) -> str:
    is_sale = kind == "sale"
    key = "Piece" if mode == "cash" else ("Weight-Kg" if mode == "upi" else "Product-04")
    product = ctx.run.products[key]
    account_kind = "creditor" if is_sale else "debtor"
    accounts = ctx.run.creditors if is_sale else ctx.run.debtors
    account = accounts[0]
    if not account:
        raise AssertionError(f"Test {account_kind} was not created.")
    await ctx.go("stock")
    before_stock = await ctx.stock(product.name)
    before_balance = await account_balance(ctx, account_kind, account) if mode == "credit_adjustment" else None
    await ctx.go("returns")
    button = "#saleReturnBtn" if is_sale else "#purchaseReturnBtn"
    await ctx.session.click(ctx.page.locator(button))
    form = ctx.page.locator("#returnFormInner")
    await form.wait_for(state="visible")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    qty, unit = (1, "piece") if product.unit == "piece" else (
        (1, "kg") if product.price_unit == "kg" else (1000, "grams")
    )
    await ctx.form_fill(form, "qty", qty)
    await ctx.form_select(form, "unit", unit)
    price = product.selling_price if is_sale else product.purchase_price
    await ctx.form_fill(form, "price", price)
    await ctx.form_select(form, "mode", mode)
    if mode == "credit_adjustment":
        await ctx.select_option_containing(await ctx.field(form, "account"), account.name)
    amount = qty * price
    await ctx.session.click(form.get_by_role("button", name="Confirm Return", exact=True))
    feedback = await ctx.wait_toast("success", timeout_ms=15_000)
    await ctx.page.locator("#returnFormInner").wait_for(state="detached", timeout=12_000)
    await ctx.go("stock")
    base = qty if product.unit == "piece" else (qty * 1000 if unit == "kg" else qty)
    expected_stock = before_stock + base if is_sale else before_stock - base
    after_stock = await ctx.wait_stock_value(product.name, expected_stock)
    if after_stock != expected_stock:
        raise AssertionError(f"{kind} return stock expected {expected_stock}; found {after_stock}.")
    if mode == "credit_adjustment":
        after_balance = await account_balance(ctx, account_kind, account)
        expected_balance = before_balance - amount if is_sale else before_balance - amount
        if after_balance < -0.01 or after_balance > before_balance + 0.01:
            raise AssertionError(
                f"{account_kind} adjustment should reduce outstanding from {before_balance:.2f}; "
                f"found {after_balance:.2f}."
            )
        if before_balance is not None and before_balance >= amount - 0.01:
            if abs(after_balance - expected_balance) > 0.01:
                raise AssertionError(
                    f"Expected {account_kind} balance {expected_balance:.2f}; found {after_balance:.2f}."
                )
    await ctx.go("returns")
    return_row = ctx.page.get_by_role("row").filter(has_text=product.name).first
    row_text = await return_row.inner_text()
    for token in (kind, mode):
        if token.casefold() not in row_text.casefold():
            raise AssertionError(f"Return history row omitted {token!r}: {row_text}")
    if not feedback:
        raise AssertionError(
            f"{kind.title()} return updated stock/history, but no visible success confirmation appeared."
        )
    ctx.run.activity["returns"] = ctx.run.activity.get("returns", 0) + 1
    return (
        f"{kind} return {mode}: stock {before_stock} → {after_stock}; "
        f"amount ₹{amount:.2f}; history row verified; feedback: {feedback}"
    )


async def run(ctx: ScenarioContext) -> None:
    await ensure_accounts(ctx)
    for mode in ("cash", "upi", "credit_adjustment"):
        await ctx.step(
            f"Returns: purchase return by {mode}",
            "Purchase return reduces stock, writes a return history row, applies any debtor balance change, and confirms success.",
            lambda mode=mode: make_return(ctx, "purchase", mode),
        )
    for mode in ("cash", "upi", "credit_adjustment"):
        await ctx.step(
            f"Returns: sale return by {mode}",
            "Sale return restores stock, writes a return history row, applies any creditor balance change, and confirms success.",
            lambda mode=mode: make_return(ctx, "sale", mode),
        )
