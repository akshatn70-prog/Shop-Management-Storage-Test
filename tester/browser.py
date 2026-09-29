from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path

from playwright.async_api import BrowserContext, Locator, Page, async_playwright


class LoginRequired(RuntimeError):
    """The user did not complete manual login before the configured deadline."""


class RunCancelled(RuntimeError):
    """The user requested that the run stop."""


@dataclass
class BrowserSession:
    page: Page
    context: BrowserContext
    playwright: object
    screenshot_dir: Path
    cancel_event: asyncio.Event
    _dialog_answers: list[str] = field(default_factory=list)
    _confirm_allowed: bool = False
    _toast_checkpoint: int = 0

    def queue_prompts(self, *answers: str) -> None:
        self._dialog_answers.extend(answers)

    def confirm_next(self) -> None:
        self._confirm_allowed = True

    def reset_dialog_responses(self) -> None:
        self._dialog_answers.clear()
        self._confirm_allowed = False

    async def _handle_dialog(self, dialog) -> None:
        if dialog.type == "prompt":
            if self._dialog_answers:
                await dialog.accept(self._dialog_answers.pop(0))
            else:
                await dialog.dismiss()
        elif dialog.type == "confirm":
            accept = self._confirm_allowed
            self._confirm_allowed = False
            if accept:
                await dialog.accept()
            else:
                await dialog.dismiss()
        else:
            await dialog.accept()

    async def _check_cancelled(self) -> None:
        if self.cancel_event.is_set():
            raise RunCancelled("Cancellation requested.")

    async def scroll_to(self, locator: Locator, timeout_ms: int = 10_000) -> None:
        """Reveal a control by scrolling its vertical and horizontal scroll parents."""
        await self._check_cancelled()
        await locator.wait_for(state="attached", timeout=timeout_ms)
        # Native scrollIntoView handles nested vertical and horizontal scroll areas
        # without relying on a stale rectangle while the page is moving.
        await locator.evaluate(
            "element => element.scrollIntoView({block: 'center', inline: 'center', behavior: 'auto'})"
        )
        await locator.wait_for(state="visible", timeout=timeout_ms)

    async def _mark_toast_checkpoint(self) -> None:
        try:
            self._toast_checkpoint = await self.page.evaluate(
                "() => (window.__testerToastEvents || []).length"
            )
        except Exception:
            self._toast_checkpoint = 0

    async def click(self, locator: Locator, timeout_ms: int = 10_000) -> None:
        await self._check_cancelled()
        await locator.wait_for(state="visible", timeout=timeout_ms)
        await self.scroll_to(locator, timeout_ms)
        if not await locator.is_enabled():
            raise RuntimeError("The target control is disabled.")
        await self._mark_toast_checkpoint()
        await locator.click(timeout=timeout_ms)

    async def dblclick(self, locator: Locator, timeout_ms: int = 10_000) -> None:
        """Dispatch two clicks on the same located node to exercise duplicate guards."""
        await self._check_cancelled()
        await locator.wait_for(state="visible", timeout=timeout_ms)
        await self.scroll_to(locator, timeout_ms)
        if not await locator.is_enabled():
            raise RuntimeError("The target control is disabled.")
        await self._mark_toast_checkpoint()
        await locator.evaluate(
            """element => {
              element.dispatchEvent(new MouseEvent("click", {bubbles: true, view: window}));
              element.dispatchEvent(new MouseEvent("click", {bubbles: true, view: window}));
            }"""
        )

    async def fill(self, locator: Locator, value: str, timeout_ms: int = 10_000) -> None:
        await self._check_cancelled()
        await locator.wait_for(state="visible", timeout=timeout_ms)
        await self.scroll_to(locator, timeout_ms)
        if not await locator.is_enabled():
            raise RuntimeError("The target field is disabled.")
        await locator.fill(value)

    async def select(self, locator: Locator, value: str, timeout_ms: int = 10_000) -> None:
        await self._check_cancelled()
        await locator.wait_for(state="visible", timeout=timeout_ms)
        await self.scroll_to(locator, timeout_ms)
        if not await locator.is_enabled():
            raise RuntimeError("The target selector is disabled.")
        await locator.select_option(value)

    async def read_text(self, locator: Locator, timeout_ms: int = 10_000) -> str:
        await self._check_cancelled()
        await locator.wait_for(state="visible", timeout=timeout_ms)
        await self.scroll_to(locator, timeout_ms)
        return (await locator.inner_text()).strip()

    async def screenshot(self, name: str) -> Path:
        self.screenshot_dir.mkdir(parents=True, exist_ok=True)
        path = self.screenshot_dir / f"{_safe_name(name)}.png"
        await self.page.screenshot(path=str(path), full_page=True)
        return path


def _safe_name(value: str) -> str:
    safe = "".join(ch.lower() if ch.isalnum() else "-" for ch in value)
    return "-".join(part for part in safe.split("-") if part)[:100] or "screenshot"


async def open_browser(
    app_url: str,
    profile_dir: Path,
    screenshot_dir: Path,
    wait_after_open_ms: int,
    cancel_event: asyncio.Event,
) -> BrowserSession:
    if not app_url:
        raise ValueError("APP_URL is required.")
    profile_dir.mkdir(parents=True, exist_ok=True)
    screenshot_dir.mkdir(parents=True, exist_ok=True)
    playwright = await async_playwright().start()
    context = None
    try:
        context = await playwright.chromium.launch_persistent_context(
            user_data_dir=str(profile_dir),
            headless=False,
            viewport={"width": 1440, "height": 1000},
            accept_downloads=True,
        )
        page = context.pages[0] if context.pages else await context.new_page()
        session = BrowserSession(page, context, playwright, screenshot_dir, cancel_event)
        page.on("dialog", session._handle_dialog)
        await page.goto(app_url, wait_until="domcontentloaded", timeout=60_000)
        await page.evaluate("""() => {
          window.__testerToastEvents = [];
          const capture = node => {
            if (!(node instanceof Element)) return;
            const toasts = [];
            if (node.matches('.toast')) toasts.push(node);
            toasts.push(...node.querySelectorAll('.toast'));
            for (const toast of toasts) window.__testerToastEvents.push({
              classes: [...toast.classList], text: (toast.textContent || '').trim(), at: Date.now()
            });
          };
          new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) capture(node);
          }).observe(document.body, {childList: true, subtree: true});
        }""")
        try:
            await page.wait_for_load_state("networkidle", timeout=20_000)
        except Exception:
            # Realtime connections may prevent networkidle; continue with the configured login wait.
            pass
        try:
            await asyncio.wait_for(
                cancel_event.wait(),
                timeout=max(0, wait_after_open_ms) / 1000,
            )
            raise RunCancelled("Cancellation requested.")
        except asyncio.TimeoutError:
            pass
        return session
    except BaseException:
        if context:
            await context.close()
        await playwright.stop()
        raise


async def close_browser(session: BrowserSession) -> None:
    try:
        await session.context.close()
    finally:
        await session.playwright.stop()
