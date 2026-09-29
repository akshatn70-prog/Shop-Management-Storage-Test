from __future__ import annotations

import asyncio
import os
import time
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

from browser import LoginRequired, RunCancelled, close_browser, open_browser
from data_factory import RunContext, make_run_id
from locators import dashboard_heading, history_heading, history_navigation, is_dashboard_visible
from report import RunReport, TestResult, create_report
from scenarios.common import ScenarioContext
from scenarios import carts, history_reports, payments, products, purchases, returns, sales, voids


TESTER_DIR = Path(__file__).resolve().parent
load_dotenv(TESTER_DIR / ".env")
CONFIRMATION = "I_CONFIRM_THIS_IS_A_DEDICATED_TEST_SHOP"


def _setting_path(name: str, default: str) -> Path:
    value = Path(os.getenv(name, default))
    return value if value.is_absolute() else (TESTER_DIR.parent / value).resolve()


async def run_suite(progress_callback=None, cancel_event: asyncio.Event | None = None) -> RunReport:
    """Run visible-UI workflows; all writes are gated to an acknowledged test shop."""
    cancel_event = cancel_event or asyncio.Event()
    app_url = os.getenv("APP_URL", "").strip()
    wait_ms = int(os.getenv("WAIT_AFTER_OPEN_MS", "30000"))
    profile_dir = _setting_path("TEST_PROFILE_DIR", "tester/state/browser-profile")
    report_dir = _setting_path("REPORT_DIR", "tester/reports")
    screenshot_dir = _setting_path("SCREENSHOT_DIR", "tester/screenshots")
    started = datetime.now().astimezone()
    run_id = make_run_id(started)
    results: list[TestResult] = []
    run = RunContext(session=None, run_id=run_id, results=results, progress_callback=progress_callback)
    session = None
    clock = time.monotonic()

    async def progress(message: str) -> None:
        if progress_callback:
            await progress_callback(message)

    try:
        await progress("Opening the app. Sign in manually now. Testing starts after 30 seconds.")
        session = await open_browser(app_url, profile_dir, screenshot_dir, wait_ms, cancel_event)
        run.session = session
        if not await is_dashboard_visible(session.page):
            screenshot = await session.screenshot(f"{run_id}-startup-blocked")
            results.append(TestResult(
                name="Startup: manual login and Dashboard", status="BLOCKED",
                expected="Dashboard visible after manual login",
                actual="Dashboard was not visible after the configured wait.",
                duration_ms=int((time.monotonic() - clock) * 1000),
                screenshot=str(screenshot),
                error="Manual login was not completed or the app did not reach its Dashboard.",
            ))
            raise LoginRequired("Manual login was not completed.")
        results.append(TestResult(
            name="Startup: manual login and Dashboard", status="PASS",
            expected="Dashboard visible after manual login",
            actual=await session.read_text(dashboard_heading(session.page)),
            duration_ms=int((time.monotonic() - clock) * 1000),
        ))
        if not await session.page.locator('[data-nav="settings"]').count():
            results.append(TestResult(
                name="Preflight: owner account", status="BLOCKED",
                expected="Owner role is required for the configured workflows",
                actual="Owner-only Settings navigation is not present.",
                duration_ms=0, error="Sign in with the dedicated test owner account.",
            ))
            return create_report(run_id, started, datetime.now().astimezone(), results, report_dir)

        enabled = os.getenv("ENABLE_TEST_DATA_WRITES", "").strip().lower() == "true"
        confirmation = os.getenv("TEST_SHOP_CONFIRMATION", "").strip()
        if not enabled or confirmation != CONFIRMATION:
            results.append(TestResult(
                name="Preflight: dedicated test shop write gate", status="BLOCKED",
                expected="Enable writes and confirm the dedicated test shop in tester/.env",
                actual="Data-writing workflows were not started.",
                duration_ms=0,
                error="Set ENABLE_TEST_DATA_WRITES=true and TEST_SHOP_CONFIRMATION=I_CONFIRM_THIS_IS_A_DEDICATED_TEST_SHOP only after confirming this owner account uses the dedicated test shop.",
            ))
            return create_report(run_id, started, datetime.now().astimezone(), results, report_dir)

        await progress("Dashboard verified. Opening History before test setup.")
        await session.click(history_navigation(session.page))
        await history_heading(session.page).wait_for(state="visible", timeout=15_000)
        shot = await session.screenshot(f"{run_id}-history-start")
        results.append(TestResult(
            name="Startup: navigate to History", status="PASS",
            expected="Sales History opens and can be captured",
            actual=await session.read_text(history_heading(session.page)),
            duration_ms=int((time.monotonic() - clock) * 1000),
            screenshot=str(shot),
        ))

        context = ScenarioContext(run)
        suites = [
            ("Products and stock setup", products.run),
            ("Purchases and accounts", purchases.run),
            ("Purchase payment validation", purchases.invalid_split_suite),
            ("Single-item sales", sales.run),
            ("Multi-item carts", carts.run),
            ("Cart payment validation", carts.invalid_split_suite),
            ("Creditor and debtor payments", payments.run),
            ("Returns", returns.run),
            ("History, stats, and reports", history_reports.run),
            ("Scroll movement", history_reports.scroll_sweep),
            ("Voids", voids.run),
        ]
        for suite_name, suite in suites:
            if cancel_event.is_set():
                raise RunCancelled("Cancellation requested.")
            await progress(f"Starting suite: {suite_name}.")
            try:
                await suite(context)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                results.append(TestResult(
                    name=f"Suite runner: {suite_name}", status="FAIL",
                    expected="Suite completes and reports its individual checks.",
                    actual=f"{type(exc).__name__}: {exc}", duration_ms=0, error=str(exc),
                ))
        await progress("All configured suites finished. Writing the report.")
    except asyncio.CancelledError as exc:
        if not any(r.error == "Cancellation requested." for r in results):
            results.append(TestResult(
                name="Run cancellation", status="BLOCKED",
                expected="Stop after the current browser action",
                actual="Cancellation was requested.",
                duration_ms=int((time.monotonic() - clock) * 1000),
                error="Cancellation requested.",
            ))
    except (LoginRequired, RunCancelled) as exc:
        if isinstance(exc, RunCancelled) and not any(r.error == "Cancellation requested." for r in results):
            results.append(TestResult(
                name="Run cancellation", status="BLOCKED",
                expected="Stop after the current browser action",
                actual="Cancellation was requested.",
                duration_ms=int((time.monotonic() - clock) * 1000), error=str(exc),
            ))
    except Exception as exc:
        screenshot_path = None
        if session:
            try:
                screenshot_path = str(await session.screenshot(f"{run_id}-runner-failure"))
            except Exception:
                pass
        results.append(TestResult(
            name="Test runner", status="FAIL",
            expected="Complete the UI test run and produce a report.",
            actual=f"{type(exc).__name__}: {exc}",
            duration_ms=int((time.monotonic() - clock) * 1000),
            screenshot=screenshot_path, error=str(exc),
        ))
    finally:
        if session:
            await close_browser(session)
    return create_report(run_id, started, datetime.now().astimezone(), results, report_dir)
