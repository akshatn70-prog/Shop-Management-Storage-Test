from __future__ import annotations

from playwright.async_api import Locator, Page


def dashboard_heading(page: Page) -> Locator:
    return page.get_by_role("heading", name="Dashboard", exact=True)


def app_shell(page: Page) -> Locator:
    return page.locator(".app-shell")


def history_navigation(page: Page) -> Locator:
    # The current app renders each bottom-navigation item as a button with data-nav.
    return page.locator('[data-nav="history"]')


def history_heading(page: Page) -> Locator:
    return page.get_by_role("heading", name="Sales History", exact=False)


def login_indicators(page: Page) -> Locator:
    return (
        page.locator('input[type="password"], #loginForm, #ownerReg')
        .or_(page.get_by_text("Connect your database", exact=False))
        .or_(page.get_by_text("Sign in", exact=False))
    )


async def is_dashboard_visible(page: Page) -> bool:
    try:
        await dashboard_heading(page).wait_for(state="visible", timeout=1_500)
        return await app_shell(page).count() > 0
    except Exception:
        return False


async def is_login_visible(page: Page) -> bool:
    try:
        await login_indicators(page).first.wait_for(state="visible", timeout=500)
        return True
    except Exception:
        return False
