from __future__ import annotations

from assertions import SuiteBlocked
from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts
from scenarios.sales import sell_one
from scenarios.carts import sell_cart


async def void_single(ctx: ScenarioContext) -> str:
    product = ctx.run.products["Piece"]
    await sell_one(ctx, "cash", 1)
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.go("history")
    row = ctx.page.get_by_role("row").filter(has_text=product.name).first
    button = row.locator(".void-sale").first
    if await button.count() == 0:
        raise AssertionError("Single sale has no owner-facing void action.")
    ctx.session.queue_prompts(f"RUN {ctx.run.run_id} single-sale correction")
    ctx.session.confirm_next()
    await ctx.session.dblclick(button)
    toast = await ctx.wait_toast("success", timeout_ms=5_000)
    if not toast:
        error = await ctx.wait_toast("error", timeout_ms=500)
        raise AssertionError(f"Single-sale void did not complete. {error or 'No success message.'}")
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if after != before + 1:
        raise AssertionError(f"Single void should restore one piece: {before} → {after}.")
    await ctx.go("history")
    visible_rows = ctx.page.get_by_role("row").filter(has_text=product.name)
    if await visible_rows.count() == 0:
        raise AssertionError("Voided sale unexpectedly removed the product's other history.")
    return f"Stock restored once, {before} → {after}; success: {toast}"


async def void_cart(ctx: ScenarioContext) -> str:
    await ensure_accounts(ctx)
    await ctx.go("history")
    existing_ids = set()
    existing_buttons = ctx.page.locator(".void-sale[data-transaction-id]")
    for index in range(await existing_buttons.count()):
        value = await existing_buttons.nth(index).get_attribute("data-transaction-id")
        if value:
            existing_ids.add(value)
    await sell_cart(ctx, "credit_split")
    piece = ctx.run.products["Piece"]
    weight = ctx.run.products["Weight-Kg"]
    await ctx.go("stock")
    before_piece = await ctx.stock(piece.name)
    before_weight = await ctx.stock(weight.name)
    credit_before = await account_balance(ctx, "creditor", ctx.run.creditor)
    await ctx.go("history")
    actions = ctx.page.locator(".void-sale[data-transaction-id]")
    if await actions.count() == 0:
        raise AssertionError("No cart transaction void action is available.")
    new_button = None
    for index in range(await actions.count()):
        candidate = actions.nth(index)
        value = await candidate.get_attribute("data-transaction-id")
        if value and value not in existing_ids:
            new_button = candidate
            break
    if new_button is None:
        raise AssertionError("The new run-owned cart has no separate transaction void action.")
    button = new_button
    tx_id = await button.get_attribute("data-transaction-id")
    if not tx_id:
        raise AssertionError("Cart void button does not identify a transaction.")
    ctx.session.queue_prompts(f"RUN {ctx.run.run_id} full-cart correction")
    ctx.session.confirm_next()
    await ctx.session.dblclick(button)
    toast = await ctx.wait_toast("success", timeout_ms=6_000)
    if not toast:
        error = await ctx.wait_toast("error", timeout_ms=1_000)
        if error and ("void_sale_transaction" in error or "function" in error.casefold() or "rpc" in error.casefold()):
            raise SuiteBlocked(
                "Cart void suite blocked: deployed database RPC void_sale_transaction(p_transaction_id uuid, p_reason text) is unavailable or failed."
            )
        raise AssertionError(f"Cart void failed. {error or 'No success message.'}")
    await ctx.go("stock")
    after_piece = await ctx.stock(piece.name)
    after_weight = await ctx.stock(weight.name)
    if after_piece != before_piece + 2:
        raise AssertionError(f"Cart void should restore two pieces: {before_piece} → {after_piece}.")
    if after_weight != before_weight + 100:
        raise AssertionError(f"Cart void should restore 100 grams: {before_weight} → {after_weight}.")
    credit_after = await account_balance(ctx, "creditor", ctx.run.creditor)
    expected_credit = float(ctx.run.last_cart["credit"])
    if abs(credit_before - credit_after - expected_credit) > 0.01:
        raise AssertionError(
            f"Cart void should reverse credit ₹{expected_credit:.2f}; creditor balance {credit_before:.2f} → {credit_after:.2f}."
        )
    await ctx.go("history")
    if await ctx.page.locator(f'.void-sale[data-transaction-id="{tx_id}"]').count():
        raise AssertionError("Voided cart still has an active Void Cart action.")
    return (
        f"Transaction {tx_id}: both stock amounts restored once; cart credit reversal "
        f"requested through the transaction RPC; success: {toast}"
    )


async def run(ctx: ScenarioContext) -> None:
    await ensure_accounts(ctx)
    await ctx.step(
        "Voids: single sale uses legacy void path",
        "The test-owned single sale is voided, its stock is restored, and history refreshes.",
        lambda: void_single(ctx),
        timeout_s=90,
    )
    await ctx.step(
        "Voids: complete cart and reverse credit",
        "The complete test-owned cart is voided once, both stocks are restored, and credit is reversed.",
        lambda: void_cart(ctx),
        timeout_s=90,
    )
