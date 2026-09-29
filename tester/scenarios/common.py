from __future__ import annotations

import asyncio
import re
import time
from typing import Awaitable, Callable

from assertions import SuiteBlocked
from browser import RunCancelled
from report import TestResult


class ScenarioContext:
    def __init__(self, run):
        self.run = run
        self.session = run.session
        self.page = run.session.page
        self.cancel_event = self.session.cancel_event
        self.current = ""

    async def checkpoint(self) -> None:
        if self.cancel_event.is_set():
            raise asyncio.CancelledError("Stop requested.")

    def nav(self, name: str):
        return self.page.locator(f'[data-nav="{name}"]')

    async def go(self, name: str) -> None:
        await self.checkpoint()
        target = self.nav(name)
        await self.session.click(target)
        await self.page.locator("#view").wait_for(state="visible", timeout=10_000)

    async def field(self, form, name: str):
        return form.locator(f'[name="{name}"]')

    async def form_fill(self, form, name: str, value: str | float | int) -> None:
        await self.session.fill(await self.field(form, name), str(value))

    async def form_select(self, form, name: str, value: str) -> None:
        await self.session.select(await self.field(form, name), value)

    async def select_option_containing(self, select, text: str) -> str:
        options = await select.locator("option").evaluate_all(
            "nodes => nodes.map(x => ({value: x.value, text: x.textContent || ''}))"
        )
        match = next((item for item in options if text.casefold() in item["text"].casefold()), None)
        if not match:
            raise AssertionError(f"No option contains {text!r}.")
        await self.session.select(select, match["value"])
        selected_text = (await select.locator("option:checked").inner_text()).strip()
        if text.casefold() not in selected_text.casefold():
            raise AssertionError(f"Could not select {text!r}; selected option is {selected_text!r}.")
        return match["value"]

    async def wait_toast(self, kind: str = "success", timeout_ms: int = 4000) -> str | None:
        deadline = time.monotonic() + timeout_ms / 1000
        checkpoint = self.session._toast_checkpoint
        while time.monotonic() < deadline:
            try:
                events = await self.page.evaluate(
                    "({since}) => (window.__testerToastEvents || []).slice(since)",
                    {"since": checkpoint},
                )
                match = next(
                    (event for event in reversed(events) if kind in event.get("classes", [])),
                    None,
                )
                if match:
                    return match.get("text") or None
            except Exception:
                pass
            await self.page.wait_for_timeout(80)
        return None

    async def wait_success(self, expected_text: str | None = None, timeout_ms: int = 5000) -> str:
        return await self.require_feedback("success", expected_text, timeout_ms)

    async def require_feedback(
        self, kind: str = "success", expected_text: str | None = None, timeout_ms: int = 4000
    ) -> str:
        text = await self.wait_toast(kind, timeout_ms)
        if not text:
            raise AssertionError(f"No visible {kind} confirmation appeared.")
        if expected_text and expected_text.casefold() not in text.casefold():
            raise AssertionError(f"Expected confirmation containing {expected_text!r}; found {text!r}.")
        return text

    async def stock(self, product_name: str) -> float:
        rows = self.page.get_by_role("row").filter(has_text=product_name)
        if await rows.count() == 0:
            raise AssertionError(f"Product {product_name!r} is not visible in Stock.")
        text = (await rows.first.inner_text()).replace(",", "")
        match = re.search(r"(?<![\w.])(\d+(?:\.\d+)?)\s*(?:pcs|g)\b", text, re.IGNORECASE)
        if not match:
            raise AssertionError(f"Could not read stock from row: {text}")
        return float(match.group(1))

    async def stock_row(self, product_name: str) -> str:
        rows = self.page.get_by_role("row").filter(has_text=product_name)
        if not await rows.count():
            raise AssertionError(f"Product {product_name!r} is not visible in Stock.")
        return await rows.first.inner_text()

    async def row_text(self, product_name: str) -> str:
        rows = self.page.get_by_role("row").filter(has_text=product_name)
        if not await rows.count():
            raise AssertionError(f"No visible table row contains {product_name!r}.")
        return await rows.first.inner_text()

    async def wait_product(self, name: str, timeout_ms: int = 12_000) -> str:
        row = self.page.get_by_role("row").filter(has_text=name).first
        await row.wait_for(state="visible", timeout=timeout_ms)
        return await row.inner_text()

    async def wait_product_text_contains(self, name: str, expected: str, timeout_ms: int = 12_000) -> str:
        deadline = time.monotonic() + timeout_ms / 1000
        last_text = ""
        while time.monotonic() < deadline:
            try:
                last_text = await self.row_text(name)
                if expected.casefold() in last_text.casefold():
                    return last_text
            except AssertionError:
                pass
            await self.page.wait_for_timeout(100)
        raise AssertionError(f"Stock row for {name!r} did not show {expected!r}; last row: {last_text}")

    async def wait_product_gone(self, name: str, timeout_ms: int = 12_000) -> None:
        row = self.page.get_by_role("row").filter(has_text=name).first
        await row.wait_for(state="detached", timeout=timeout_ms)

    async def step(self, name: str, expected: str, operation: Callable[[], Awaitable[str | None]], *, timeout_s: float = 60) -> None:
        self.current = name
        self.session.reset_dialog_responses()
        started = time.monotonic()
        try:
            await self.checkpoint()
            actual = await asyncio.wait_for(operation(), timeout=timeout_s)
            self.run.results.append(TestResult(
                name=name, status="PASS", expected=expected,
                actual=actual or "Expected UI and resulting data were verified.",
                duration_ms=int((time.monotonic() - started) * 1000),
            ))
        except SuiteBlocked as exc:
            screenshot = await self._screenshot(name)
            self.run.results.append(TestResult(
                name=name, status="BLOCKED", expected=expected, actual=str(exc),
                duration_ms=int((time.monotonic() - started) * 1000),
                screenshot=screenshot, error=str(exc),
            ))
        except RunCancelled:
            screenshot = await self._screenshot(name)
            self.run.results.append(TestResult(
                name=name, status="BLOCKED", expected=expected,
                actual="Run stopped at the user's request.",
                duration_ms=int((time.monotonic() - started) * 1000),
                screenshot=screenshot, error="Cancellation requested.",
            ))
            await self._progress_if_due(force=True)
            raise asyncio.CancelledError("Cancellation requested.")
        except asyncio.CancelledError:
            screenshot = await self._screenshot(name)
            self.run.results.append(TestResult(
                name=name, status="BLOCKED", expected=expected,
                actual="Run stopped at the user's request.",
                duration_ms=int((time.monotonic() - started) * 1000),
                screenshot=screenshot, error="Cancellation requested.",
            ))
            await self._progress_if_due(force=True)
            raise
        except Exception as exc:
            screenshot = await self._screenshot(name)
            self.run.results.append(TestResult(
                name=name, status="FAIL", expected=expected,
                actual=f"{type(exc).__name__}: {exc}",
                duration_ms=int((time.monotonic() - started) * 1000),
                screenshot=screenshot, error=str(exc),
            ))
        await self._progress_if_due()

    async def _progress_if_due(self, force: bool = False) -> None:
        completed = len(self.run.results)
        callback = self.run.progress_callback
        if callback and (force or completed % 5 == 0):
            await callback(f"Completed {completed} checks; most recent: {self.current}.")

    async def _screenshot(self, name: str) -> str | None:
        try:
            return str(await self.session.screenshot(f"{self.run.run_id}-{name}-failure"))
        except Exception:
            return None
