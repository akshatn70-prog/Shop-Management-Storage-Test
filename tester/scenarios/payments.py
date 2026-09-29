from __future__ import annotations

import asyncio
import time

from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts


async def _wait_balance(ctx: ScenarioContext, kind: str, account, expected: float) -> float:
    deadline = time.monotonic() + 15
    latest = None
    while time.monotonic() < deadline:
        latest = await account_balance(ctx, kind, account)
        if abs(latest - expected) <= 0.01:
            return latest
        await asyncio.sleep(0.25)
    raise AssertionError(f"{kind.title()} balance did not update to {expected:.2f}; found {latest}.")


async def _pay(ctx: ScenarioContext, kind: str, mode: str, account_index: int) -> str:
    await ensure_accounts(ctx)
    accounts = ctx.run.creditors if kind == "creditor" else ctx.run.debtors
    account = accounts[account_index]
    before = await account_balance(ctx, kind, account)
    if before < 1:
        raise AssertionError(f"Test {kind} has no outstanding amount to pay: {before:.2f}.")
    amount = 1.0
    await ctx.go("creditors" if kind == "creditor" else "debtors")
    row = ctx.page.get_by_role("row").filter(has_text=account.name)
    prompts = [str(amount), mode]
    if mode == "split":
        prompts.append(str(amount / 2))
    ctx.session.queue_prompts(*prompts)
    await ctx.session.click(row.get_by_role("button", name="Pay", exact=True))
    after = await _wait_balance(ctx, kind, account, before - amount)
    feedback = await ctx.wait_toast("success", timeout_ms=15_000)
    if not feedback:
        raise AssertionError(
            f"{kind.title()} balance changed from {before:.2f} to {after:.2f}, "
            "but no visible success confirmation appeared."
        )
    ctx.run.activity["account_payments"] = ctx.run.activity.get("account_payments", 0) + 1
    return f"{kind.title()} balance {before:.2f} → {after:.2f}; mode {mode}; feedback: {feedback}"


async def run(ctx: ScenarioContext) -> None:
    await ensure_accounts(ctx)
    modes = ("cash", "upi", "split")
    for index, account in enumerate(ctx.run.creditors):
        mode = modes[index % len(modes)]
        await ctx.step(
            f"Payments: settle {account.name} by {mode}",
            "Each creditor payment lowers the right balance and confirms completion.",
            lambda mode=mode, index=index: _pay(ctx, "creditor", mode, index),
        )
    for index, account in enumerate(ctx.run.debtors):
        mode = modes[index % len(modes)]
        await ctx.step(
            f"Payments: settle {account.name} by {mode}",
            "Each debtor payment lowers the right balance and confirms completion.",
            lambda mode=mode, index=index: _pay(ctx, "debtor", mode, index),
        )
