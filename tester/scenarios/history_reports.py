from __future__ import annotations

import re
from datetime import datetime

from assertions import money_close
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
    rows = ctx.page.locator("tbody tr").filter(has_text=ctx.run.products["Piece"].name)
    count = await rows.count()
    if count < 5:
        raise AssertionError(f"Expected the five single-sale payment cases; found {count} rows.")
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
    return f"Cross-checked {checked} single-sale rows: cash + UPI + credit equals each sale total."

async def sales_credit_crosscheck(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Sales", exact=True))
    rows = ctx.page.locator("tbody tr").filter(has_text="Cart")
    count = await rows.count()
    if count < 2:
        raise AssertionError(f"Expected cart sale lines in History; found {count}.")
    checked = 0
    for index in range(count):
        row = rows.nth(index)
        text = await row.inner_text()
        if not any(product in text for product in (ctx.run.products["Piece"].name, ctx.run.products["Weight-Kg"].name)):
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
    if checked < 2:
        raise AssertionError("Did not cross-check at least two mixed-cart product lines.")
    return f"Cross-checked {checked} cart lines: displayed cash + UPI + credit equals each line total."


async def purchase_history(ctx: ScenarioContext) -> str:
    await ctx.go("history")
    await ctx.session.click(ctx.page.get_by_role("button", name="Purchases", exact=True))
    piece_name = ctx.run.products["Piece"].name
    rows = ctx.page.locator("tbody tr").filter(has_text=piece_name)
    if await rows.count() < 3:
        raise AssertionError("Cash/UPI/split/credit purchases were not all visible in Purchase History.")
    text = "\n".join(await rows.all_inner_texts())
    if "pre_stock" in text.casefold() or "pre-stock" in text.casefold():
        raise AssertionError("Pre-stock recording should not appear as a financial purchase.")
    return f"{await rows.count()} purchase-history rows visible; pre-stock remains excluded."


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
