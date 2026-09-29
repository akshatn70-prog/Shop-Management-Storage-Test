from __future__ import annotations

import re
import os
from datetime import datetime

from assertions import SuiteBlocked, money_close
from scenarios.common import ScenarioContext
from scenarios.purchases import account_balance, ensure_accounts


def _money(text: str) -> float:
    match = re.search(r"₹\s*([0-9,]+(?:\.[0-9]{1,2})?)", text)
    if not match:
        raise AssertionError(f"Could not read money from {text!r}.")
    return float(match.group(1).replace(",", ""))



async def sales_history_crosscheck(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Sales", exact=True))
    rows = ctx.page.locator("tbody tr").filter(has_text=f"RUN-{ctx.run.run_id}-")
    count = await rows.count()
    if count < 50:
        raise AssertionError(f"Expected at least 50 test sale lines, including cart items; found {count} rows.")
    checked = 0
    for index in range(count):
        row = rows.nth(index)
        cells = row.locator("td")
        payment = await cells.nth(3).inner_text()
        total = _money(await cells.nth(4).inner_text())
        values = [_money(value) for value in re.findall(r"₹\s*[0-9,]+(?:\.[0-9]{1,2})?", payment)]
        if len(values) < 3:
            raise AssertionError(f"Payment breakdown missing on sale row: {payment}")
        money_close(sum(values[:3]), total)
        checked += 1
    return f"Cross-checked {checked} test sale lines: cash + UPI + credit equals each line total."

async def sales_credit_crosscheck(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Sales", exact=True))
    rows = ctx.page.locator("tbody tr")
    count = await rows.count()
    if count < 2:
        raise AssertionError(f"Expected cart sale lines in History; found {count}.")
    checked = 0
    for index in range(count):
        row = rows.nth(index)
        text = await row.inner_text()
        if not any(ctx.run.products[f"Cart-{key:02d}"].name in text for key in range(1, 11)):
            continue
        cells = row.locator("td")
        payment = await cells.nth(3).inner_text()
        total_text = await cells.nth(4).inner_text()
        total = _money(total_text)
        amounts = re.findall(r"Cash\s*₹\s*([0-9,]+(?:\.[0-9]{1,2})?)|UPI\s*₹\s*([0-9,]+(?:\.[0-9]{1,2})?)|Credit\s*₹\s*([0-9,]+(?:\.[0-9]{1,2})?)", payment)
        if not amounts:
            raise AssertionError(f"Payment breakdown missing on cart row: {payment}")
        values = [_money(x) for x in re.findall(r"₹\s*[0-9,]+(?:\.[0-9]{1,2})?", payment)]
        if len(values) < 3:
            raise AssertionError(f"Expected cash, UPI, and credit values in {payment!r}.")
        money_close(sum(values[:3]), total)
        checked += 1
    if checked != 10:
        raise AssertionError(f"Expected to cross-check all 10 benchmark cart lines; found {checked}.")
    return f"Cross-checked {checked} cart lines: displayed cash + UPI + credit equals each line total."


async def purchase_history(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Purchases", exact=True))
    rows = ctx.page.locator("tbody tr").filter(has_text=f"RUN-{ctx.run.run_id}-")
    if await rows.count() != 40:
        raise AssertionError(f"Expected 40 financial purchase rows; found {await rows.count()}.")
    text = "\n".join(await rows.all_inner_texts())
    if "pre_stock" in text.casefold() or "pre-stock" in text.casefold():
        raise AssertionError("Pre-stock recording should not appear as a financial purchase.")
    return f"{await rows.count()} purchase-history rows visible; pre-stock remains excluded."


async def fresh_shop_preflight(ctx: ScenarioContext) -> str:
    await ctx.go("today")
    values = await _today_metrics(ctx)
    sales = _money(values.get("Sales", "₹0"))
    profit = _money(values.get("Profit", "₹0"))
    transactions = int(re.sub(r"[^0-9]", "", values.get("Transactions", "0")) or "0")
    products = int(re.sub(r"[^0-9]", "", values.get("Products", "0")) or "0")
    resume_id = os.getenv("RESUME_RUN_ID", "").strip()
    if resume_id:
        if not re.fullmatch(r"\d{8}-\d{6}-\d{3}", resume_id):
            raise SuiteBlocked("Resume mode needs the exact run ID from the interrupted tester session.")
        if sales or profit or transactions or products != 1:
            raise SuiteBlocked(
                "The interrupted shop no longer matches the safe resume state. No new test records were created. "
                f"Current values: Sales ₹{sales:.2f}, Profit ₹{profit:.2f}, "
                f"Transactions {transactions}, Products {products}."
            )
        for tab, selector, kind in (
            ("creditors", ".credit-row", "creditor"),
            ("debtors", ".debtor-row", "debtor"),
        ):
            await ctx.go(tab)
            rows = ctx.page.locator(selector)
            if await rows.count() != 5:
                raise SuiteBlocked(f"Resume requires exactly five existing {kind} accounts.")
            for index in range(1, 6):
                expected_name = f"RUN-{resume_id}-{kind}-{index:02d}"
                match = rows.filter(has_text=expected_name)
                if await match.count() != 1:
                    raise SuiteBlocked(f"Resume could not verify the expected {kind} {index} row.")
                amounts = re.findall(r"₹\s*([0-9,]+(?:\.[0-9]{1,2})?)", await match.inner_text())
                if amounts and any(float(value.replace(",", "")) > 0.01 for value in amounts):
                    raise SuiteBlocked(f"Resume found a non-zero balance on {expected_name}.")

        await ctx.go("stock")
        stock_rows = ctx.page.locator("tbody tr")
        piece_name = f"RUN-{resume_id}-Piece"
        if await stock_rows.count() != 1 or await stock_rows.filter(has_text=piece_name).count() != 1:
            raise SuiteBlocked("Resume requires exactly the single Piece product from the interrupted run.")
        if abs(await ctx.stock(piece_name)) > 0.001:
            raise SuiteBlocked("Resume found stock on the existing Piece product; expected zero before purchases.")

        await ctx.go("history")
        for history_tab in ("Purchases", "Sales"):
            await ctx.session.click(ctx.page.get_by_role("button", name=history_tab, exact=True))
            if await ctx.page.locator("tbody tr").filter(has_text=f"RUN-{resume_id}-").count():
                raise SuiteBlocked(f"Resume found existing {history_tab.casefold()} transactions.")
        await ctx.go("returns")
        if await ctx.page.locator("tbody tr").filter(has_text=f"RUN-{resume_id}-").count():
            raise SuiteBlocked("Resume found existing return records.")
        return "Verified the interrupted run's exact setup: five zero-balance accounts and one zero-stock Piece product; safe to resume."

    if sales or profit or transactions or products:
        raise SuiteBlocked(
            "The configured shop is not fresh/empty. No test records were created. "
            f"Current values: Sales ₹{sales:.2f}, Profit ₹{profit:.2f}, "
            f"Transactions {transactions}, Products {products}."
        )
    return "Fresh shop confirmed: today has zero sales, profit, transactions, and products."


async def _today_metrics(ctx: ScenarioContext) -> dict[str, str]:
    cards = ctx.page.locator(".metric")
    values: dict[str, str] = {}
    for index in range(await cards.count()):
        card = cards.nth(index)
        label = (await card.locator("span").inner_text()).strip()
        value = (await card.locator("b").inner_text()).strip()
        values[label] = value
    return values


async def financial_targets(ctx: ScenarioContext) -> str:
    expected_activity = {
        "purchases": 50,
        "single_sales": 40,
        "cart_sales": 5,
        "returns": 6,
        "account_payments": 10,
    }
    actual_activity = {key: ctx.run.activity.get(key, 0) for key in expected_activity}
    if actual_activity != expected_activity:
        raise AssertionError(f"Expected transaction plan {expected_activity}; completed {actual_activity}.")
    total_activity = sum(actual_activity.values())
    if total_activity != 111:
        raise AssertionError(f"Expected about 100 recorded operations (111 planned); counted {total_activity}.")

    await ctx.go("today")
    values = await _today_metrics(ctx)
    sales = _money(values.get("Sales", ""))
    profit = _money(values.get("Profit", ""))
    transactions = int(re.sub(r"[^0-9]", "", values.get("Transactions", "0")) or "0")
    products = int(re.sub(r"[^0-9]", "", values.get("Products", "0")) or "0")
    money_close(sales, 25_000)
    money_close(profit, 4_000)
    if transactions != 45:
        raise AssertionError(f"Expected 45 active sale/cart transactions; Today Stats shows {transactions}.")
    if products != 50:
        raise AssertionError(f"Expected 50 active products; Today Stats shows {products}.")
    if len(ctx.run.creditors) != 5 or len(ctx.run.debtors) != 5:
        raise AssertionError(
            f"Expected 5 creditors and 5 debtors; found {len(ctx.run.creditors)} and {len(ctx.run.debtors)}."
        )
    if await ctx.page.get_by_text("Balanced", exact=True).count() == 0:
        raise AssertionError("Today Stats reconciliation did not show Balanced.")
    return (
        f"Verified {total_activity} workflow records (50 purchases, 45 sale/cart transactions, "
        f"6 returns, 10 account payments); 50 products, 5 creditors, 5 debtors; "
        f"net sales ₹{sales:.2f}, profit ₹{profit:.2f}, reconciliation balanced."
    )


async def date_filter(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Sales", exact=True))
    date_value = datetime.now().astimezone().date().isoformat()
    await ctx.session.click(ctx.page.get_by_role("button", name="Search Date", exact=True))
    await ctx.session.fill(ctx.page.locator("#historyDate"), date_value)
    await ctx.page.locator("#historyDate").dispatch_event("change")
    await ctx.page.get_by_role("heading", name="Sales History", exact=False).wait_for(state="visible")
    return f"History date filter accepted {date_value}."


async def dashboard_today(ctx: ScenarioContext) -> str:
    await ctx.go("dashboard")
    await ctx.page.get_by_role("heading", name="Dashboard", exact=True).wait_for(state="visible")
    for label in ("Today Sales", "Today Profit", "Cash", "UPI", "Credit"):
        if await ctx.page.get_by_text(label, exact=False).count() == 0:
            raise AssertionError(f"Dashboard metric {label!r} is missing.")
    await ctx.go("today")
    heading = ctx.page.get_by_role("heading", name="Today Stats", exact=False)
    await heading.wait_for(state="visible")
    return "Dashboard and Today Stats headings and all five financial metric labels are visible."


async def report_view(ctx: ScenarioContext) -> str:
    await ctx.go("reports")
    await ctx.page.get_by_role("heading", name="Reports", exact=True).wait_for(state="visible")
    table = ctx.page.locator(".reports-scroll")
    await table.wait_for(state="visible")
    credit_col = table.get_by_role("columnheader", name="Credit Profit", exact=True)
    await ctx.session.scroll_to(credit_col)
    if not await credit_col.is_visible():
        raise AssertionError("Horizontal scrolling did not reveal the Credit Profit report column.")
    return "Reports opened; horizontal scroll reached the Credit Profit column."


async def account_histories(ctx: ScenarioContext) -> str:
    await ensure_accounts(ctx)
    checked = []
    for kind, account, tab, button_sel, holder in (
        ("creditor", ctx.run.creditor, "creditors", ".credit-history", "#creditDetail"),
        ("debtor", ctx.run.debtor, "debtors", ".debtor-history", "#debtorDetail"),
    ):
        await ctx.go(tab)
        row = ctx.page.get_by_role("row").filter(has_text=account.name)
        await row.wait_for(state="visible")
        await ctx.session.click(row.locator(button_sel))
        panel = ctx.page.locator(holder)
        await panel.wait_for(state="visible")
        text = await panel.inner_text()
        if account.name not in text:
            raise AssertionError(f"{kind.title()} history did not identify the test account.")
        checked.append(f"{kind} history opened")
    return "; ".join(checked) + "."


async def run(ctx: ScenarioContext) -> None:
    await ctx.step(
        "Views: single-sale payment parts equal total",
        "Each single sale shows cash + UPI + credit equal to its total.",
        lambda: sales_history_crosscheck(ctx),
    )
    await ctx.step(
        "Views: cart credit equals total minus cash and UPI",
        "Each cart line shows correct payment components whose sum equals its line total.",
        lambda: sales_credit_crosscheck(ctx),
    )
    await ctx.step(
        "Views: purchases and pre-stock separation",
        "Purchases are visible while pre-stock entries remain excluded from financial purchase history.",
        lambda: purchase_history(ctx),
    )
    await ctx.step(
        "Views: search history by date",
        "History accepts the current date filter.",
        lambda: date_filter(ctx),
    )
    await ctx.step(
        "Views: Dashboard and Today Stats",
        "Dashboard and Today Stats show the financial metric labels.",
        lambda: dashboard_today(ctx),
    )
    await ctx.step(
        "Views: reports and horizontal navigation",
        "Reports open and horizontally scrolling reaches the Credit Profit column.",
        lambda: report_view(ctx),
    )
    await ctx.step(
        "Views: creditor and debtor histories",
        "Both test accounts open their transaction histories.",
        lambda: account_histories(ctx),
    )

async def scroll_sweep(ctx: ScenarioContext) -> str:
    async def operation() -> str:
        await ctx.go("reports")
        table = ctx.page.locator(".reports-scroll")
        await table.wait_for(state="visible")
        before = await table.evaluate("(el) => ({left: el.scrollLeft, max: el.scrollWidth - el.clientWidth})")
        await table.evaluate("el => { el.scrollTop = el.scrollHeight; el.scrollLeft = el.scrollWidth; }")
        right = await table.evaluate("el => el.scrollLeft")
        date_header = table.get_by_role("columnheader", name="Date", exact=True)
        await ctx.session.scroll_to(date_header)
        left = await table.evaluate("el => el.scrollLeft")
        credit_header = table.get_by_role("columnheader", name="Credit Profit", exact=True)
        await ctx.session.scroll_to(credit_header)
        right_again = await table.evaluate("el => el.scrollLeft")
        await ctx.page.evaluate(
            """() => {
              const root = document.scrollingElement;
              if (root) root.scrollTop = root.scrollHeight;
              for (const el of document.querySelectorAll("*")) {
                const style = getComputedStyle(el);
                if (/(auto|scroll|overlay)/.test(style.overflowY) && el.scrollHeight > el.clientHeight) {
                  el.scrollTop = el.scrollHeight;
                }
              }
            }"""
        )
        await ctx.session.click(ctx.page.locator('[data-nav="history"]'))
        await ctx.page.get_by_role("heading", name="Sales History", exact=False).wait_for(state="visible")
        if before["max"] > 0 and (right <= 0 or right_again <= left):
            raise AssertionError(
                f"Horizontal scrolling did not move across the report table: {left}, {right}, {right_again}."
            )
        return (
            f"Scrolled vertically to the page end, horizontally right to the last report columns, "
            f"back left to Date ({left}), and selected History after the layout moved."
        )

    await ctx.step(
        "Controls: scroll up/down and left/right to shifted controls",
        "The tester reaches controls after vertical and horizontal scrolling without fixed coordinates.",
        operation,
    )
