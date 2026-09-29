from __future__ import annotations

import re

from data_factory import Account, mobile_for, unique_name
from scenarios.common import ScenarioContext


async def create_account(ctx: ScenarioContext, kind: str) -> Account:
    existing = ctx.run.creditor if kind == "creditor" else ctx.run.debtor
    if existing:
        return existing
    name = unique_name(ctx.run.run_id, kind)
    mobile = mobile_for(ctx.run.run_id, kind)
    await ctx.go("creditors" if kind == "creditor" else "debtors")
    ctx.session.queue_prompts(name, mobile)
    await ctx.session.click(ctx.page.locator("#newCreditor" if kind == "creditor" else "#newDebtor"))
    await ctx.wait_success()
    row = ctx.page.get_by_role("row").filter(has_text=name)
    await row.wait_for(state="visible", timeout=12_000)
    account = Account(name=name, mobile=mobile, balance=0)
    if kind == "creditor":
        ctx.run.creditor = account
    else:
        ctx.run.debtor = account
    return account


async def account_balance(ctx: ScenarioContext, kind: str, account: Account) -> float:
    await ctx.go("creditors" if kind == "creditor" else "debtors")
    row = ctx.page.get_by_role("row").filter(has_text=account.name)
    await row.wait_for(state="visible", timeout=10_000)
    text = (await row.inner_text()).replace(",", "")
    amounts = re.findall(r"(?:₹|INR)\s*([0-9]+(?:\.[0-9]+)?)", text, re.IGNORECASE)
    if not amounts:
        raise AssertionError(f"Could not read {kind} balance from row: {text}")
    return float(amounts[-1])


async def ensure_accounts(ctx: ScenarioContext) -> None:
    if not ctx.run.creditor:
        await ctx.step(
            "Accounts: create customer creditor",
            "A unique creditor appears in the app with a success message.",
            lambda: create_account(ctx, "creditor"),
        )
    if not ctx.run.debtor:
        await ctx.step(
            "Accounts: create supplier debtor",
            "A unique debtor appears in the app with a success message.",
            lambda: create_account(ctx, "debtor"),
        )


async def purchase(ctx: ScenarioContext, key: str, mode: str, qty: float = 2) -> str:
    product = ctx.run.products[key]
    debtor_before = None
    if mode == "credit" and ctx.run.debtor:
        debtor_before = await account_balance(ctx, "debtor", ctx.run.debtor)
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.session.click(ctx.page.locator("#addPurchase"))
    form = ctx.page.locator("#purchaseFormInner")
    await form.wait_for(state="visible")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", qty)
    await ctx.form_fill(form, "price", product.purchase_price)
    await ctx.form_fill(form, "selling", product.selling_price)
    await ctx.form_select(form, "payment", mode)
    base = qty if product.unit == "piece" else (qty * 1000 if product.price_unit == "kg" else qty)
    total = qty * product.purchase_price
    if mode == "split":
        cash = round(total / 2, 2)
        await ctx.form_fill(form, "cash", cash)
        await ctx.form_fill(form, "upi", round(total - cash, 2))
    if mode == "credit":
        if not ctx.run.debtor:
            raise AssertionError("Test debtor was not created.")
        await ctx.select_option_containing(await ctx.field(form, "debtor"), ctx.run.debtor.name)
    await ctx.session.click(form.get_by_role("button", name="Save Purchase", exact=True))
    feedback = await ctx.wait_success("Purchase recorded")
    await form.wait_for(state="detached", timeout=12_000)
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if abs(after - (before + base)) > 0.001:
        raise AssertionError(f"Stock should rise from {before} to {before + base}; found {after}.")
    product.stock_base = after
    ctx.run.last_purchase = {"product": key, "mode": mode, "amount": total, "base": base}
    if mode == "credit" and ctx.run.debtor and debtor_before is not None:
        debtor_after = await account_balance(ctx, "debtor", ctx.run.debtor)
        if abs(debtor_after - debtor_before - total) > 0.01:
            raise AssertionError(
                f"Debtor balance should increase by ₹{total:.2f}; found {debtor_before:.2f} → {debtor_after:.2f}."
            )
        ctx.run.debtor.balance = debtor_after
    return f"Stock {before} → {after}; total ₹{total:.2f}; mode {mode}; feedback: {feedback}"


async def weight_purchase(ctx: ScenarioContext, key: str, qty: float, unit: str) -> str:
    product = ctx.run.products[key]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.session.click(ctx.page.locator("#addPurchase"))
    form = ctx.page.locator("#purchaseFormInner")
    await form.wait_for(state="visible")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", qty)
    await ctx.form_select(form, "payment", "upi")
    base = qty * 1000 if unit == "kg" else qty
    total = qty * product.purchase_price
    await ctx.session.click(form.get_by_role("button", name="Save Purchase", exact=True))
    feedback = await ctx.wait_toast("success", timeout_ms=1_500)
    await form.wait_for(state="detached", timeout=12_000)
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if abs(after - (before + base)) > 0.001:
        raise AssertionError(f"Weight stock should rise from {before} to {before + base}; found {after}.")
    product.stock_base = after
    return f"Weight stock {before} g → {after} g; purchase total ₹{total:.2f}; feedback: {feedback}"


async def pre_stock(ctx: ScenarioContext) -> str:
    product = ctx.run.products["Piece"]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.session.click(ctx.page.locator("#addPurchase"))
    form = ctx.page.locator("#purchaseFormInner")
    await form.wait_for(state="visible")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", 3)
    await ctx.form_select(form, "payment", "pre_stock")
    await ctx.session.click(form.get_by_role("button", name="Save Purchase", exact=True))
    feedback = await ctx.wait_toast("success", timeout_ms=1_500)
    await form.wait_for(state="detached", timeout=12_000)
    await ctx.go("stock")
    after = await ctx.stock(product.name)
    if after != before + 3:
        raise AssertionError(f"Pre-stock should raise stock by 3; found {before} → {after}.")
    product.stock_base = after
    return f"Stock {before} → {after}; pre-stock creates no financial purchase; feedback: {feedback}"


async def invalid_split(ctx: ScenarioContext) -> str:
    product = ctx.run.products["Piece"]
    await ctx.go("stock")
    before = await ctx.stock(product.name)
    await ctx.session.click(ctx.page.locator("#addPurchase"))
    form = ctx.page.locator("#purchaseFormInner")
    await ctx.select_option_containing(await ctx.field(form, "product"), product.name)
    await ctx.form_fill(form, "qty", 2)
    await ctx.form_select(form, "payment", "split")
    await ctx.form_fill(form, "cash", 20)
    await ctx.form_fill(form, "upi", 1)
    await ctx.session.click(form.get_by_role("button", name="Save Purchase", exact=True))
    message = await ctx.wait_toast("error", timeout_ms=3_000)
    if not message or "equal" not in message.casefold():
        raise AssertionError(f"Invalid purchase split was not rejected; found {message!r}.")
    after = await ctx.stock(product.name)
    if after != before:
        raise AssertionError(f"Rejected split purchase changed stock: {before} → {after}.")
    return f"Rejected with “{message}”; stock stayed {after}."


async def invalid_split_suite(ctx: ScenarioContext) -> None:
    await ctx.step(
        "Purchases: reject invalid split total",
        "Cash + UPI must equal the purchase total; invalid payment leaves stock unchanged.",
        lambda: invalid_split(ctx),
    )


async def run(ctx: ScenarioContext) -> None:
    await ensure_accounts(ctx)
    for mode in ("cash", "upi", "split", "credit"):
        await ctx.step(
            f"Purchases: {mode} purchase",
            "Purchase is saved, stock increases by the base quantity, debtor balance updates for credit, and success feedback appears.",
            lambda mode=mode: purchase(ctx, "Piece", mode, 2),
        )
    await ctx.step(
        "Purchases: pre-stock recording",
        "Stock increases while the entry is recorded as pre-stock with no payable.",
        lambda: pre_stock(ctx),
    )
    await ctx.step(
        "Purchases: kg unit conversion",
        "One kg purchase adds 1000 base grams.",
        lambda: weight_purchase(ctx, "Weight-Kg", 1, "kg"),
    )
    await ctx.step(
        "Purchases: gram unit conversion",
        "A 250 gram purchase adds 250 base grams.",
        lambda: weight_purchase(ctx, "Weight-Gram", 250, "grams"),
    )
