from __future__ import annotations

import re

from data_factory import Account, mobile_for, unique_name
from scenarios.common import ScenarioContext


async def create_account(ctx: ScenarioContext, kind: str, index: int = 1) -> Account:
    accounts = ctx.run.creditors if kind == "creditor" else ctx.run.debtors
    if len(accounts) >= index:
        return accounts[index - 1]
    name = unique_name(ctx.run.run_id, f"{kind}-{index:02d}")
    mobile = mobile_for(ctx.run.run_id, f"{kind}-{index:02d}")
    await ctx.go("creditors" if kind == "creditor" else "debtors")
    ctx.session.queue_prompts(name, mobile)
    await ctx.session.click(ctx.page.locator("#newCreditor" if kind == "creditor" else "#newDebtor"))
    await ctx.wait_success()
    row = ctx.page.get_by_role("row").filter(has_text=name)
    await row.wait_for(state="visible", timeout=12_000)
    account = Account(name=name, mobile=mobile, balance=0)
    accounts.append(account)
    if kind == "creditor" and ctx.run.creditor is None:
        ctx.run.creditor = account
    if kind == "debtor" and ctx.run.debtor is None:
        ctx.run.debtor = account
    return account


async def create_all_accounts(ctx: ScenarioContext) -> None:
    for kind in ("creditor", "debtor"):
        for index in range(1, 6):
            await ctx.step(
                f"Accounts: create {kind} {index} of 5",
                f"A unique {kind} account appears in the fresh test shop.",
                lambda kind=kind, index=index: create_account(ctx, kind, index),
            )


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
    if not ctx.run.creditors:
        await create_account(ctx, "creditor")
    if not ctx.run.debtors:
        await create_account(ctx, "debtor")


async def purchase(
    ctx: ScenarioContext, key: str, mode: str, qty: float = 2, account_index: int = 0
) -> str:
    product = ctx.run.products[key]
    debtor = ctx.run.debtors[account_index % len(ctx.run.debtors)] if ctx.run.debtors else ctx.run.debtor
    debtor_before = None
    if mode == "credit" and debtor:
        debtor_before = await account_balance(ctx, "debtor", debtor)
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
        if not debtor:
            raise AssertionError("Test debtor was not created.")
        await ctx.select_option_containing(await ctx.field(form, "debtor"), debtor.name)
    await ctx.session.click(form.get_by_role("button", name="Save Purchase", exact=True))
    feedback = await ctx.wait_success("Pre-stock recorded" if mode == "pre_stock" else "Purchase recorded")
    await form.wait_for(state="detached", timeout=12_000)
    await ctx.go("stock")
    after = await ctx.wait_stock_value(product.name, before + base)
    if abs(after - (before + base)) > 0.001:
        raise AssertionError(f"Stock should rise from {before} to {before + base}; found {after}.")
    product.stock_base = after
    ctx.run.last_purchase = {"product": key, "mode": mode, "amount": total, "base": base}
    if mode == "credit" and debtor and debtor_before is not None:
        debtor_after = await account_balance(ctx, "debtor", debtor)
        if abs(debtor_after - debtor_before - total) > 0.01:
            raise AssertionError(
                f"Debtor balance should increase by ₹{total:.2f}; found {debtor_before:.2f} → {debtor_after:.2f}."
            )
        debtor.balance = debtor_after
    ctx.run.activity["purchases"] = ctx.run.activity.get("purchases", 0) + 1
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
    modes = ("cash", "upi", "split", "credit", "pre_stock")
    for index, key in enumerate(ctx.run.products):
        mode = modes[index % len(modes)]
        await ctx.step(
            f"Purchases: {key} by {mode}",
            "Each product purchase updates stock and records the selected payment or pre-stock outcome.",
            lambda key=key, mode=mode, index=index: purchase(
                ctx,
                key,
                mode,
                10 if ctx.run.products[key].unit == "piece" and key == "Piece" else (
                    2_000 if ctx.run.products[key].unit == "grams" else 2
                ),
                (index // 5) % 5,
            ),
        )
