from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

from runner import run_suite


TESTER_DIR = Path(__file__).resolve().parent
load_dotenv(TESTER_DIR / ".env")
logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
)
logger = logging.getLogger("shop-tester")

_run_lock = asyncio.Lock()
_active_task: asyncio.Task | None = None
_cancel_event: asyncio.Event | None = None
_progress_state = "No test run is active."


def _authorized(update: Update) -> bool:
    user_setting = os.getenv("ALLOWED_TELEGRAM_USER_ID", "").strip()
    chat_setting = os.getenv("ALLOWED_TELEGRAM_CHAT_ID", "").strip()
    user_id = update.effective_user.id if update.effective_user else None
    chat_id = update.effective_chat.id if update.effective_chat else None
    return (
        (bool(user_setting) and str(user_id) == user_setting)
        or (bool(chat_setting) and str(chat_id) == chat_setting)
    )


async def _guard(update: Update) -> bool:
    if _authorized(update):
        return True
    if update.effective_message:
        await update.effective_message.reply_text(
            "This Telegram account is not on the tester allowlist. "
            "Configure ALLOWED_TELEGRAM_USER_ID or ALLOWED_TELEGRAM_CHAT_ID in tester/.env."
        )
    return False


async def _progress(chat_id: int, context: ContextTypes.DEFAULT_TYPE, message: str) -> None:
    global _progress_state
    _progress_state = message
    await context.bot.send_message(chat_id=chat_id, text=message)


async def _begin(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    global _active_task, _cancel_event
    message = update.effective_message
    chat = update.effective_chat
    if not message or not chat:
        return
    if not await _guard(update):
        return

    async with _run_lock:
        if _active_task and not _active_task.done():
            await message.reply_text("A test run is already active. Use /status to check progress.")
            return
        _cancel_event = asyncio.Event()
        cancel_event = _cancel_event
        chat_id = chat.id

        async def execute() -> None:
            global _active_task, _cancel_event, _progress_state
            try:
                report = await run_suite(
                    progress_callback=lambda text: _progress(chat_id, context, text),
                    cancel_event=cancel_event,
                )
                await context.bot.send_message(chat_id=chat_id, text=report.telegram_summary())
                if report.report_txt:
                    with open(report.report_txt, "rb") as file:
                        await context.bot.send_document(
                            chat_id=chat_id,
                            document=file,
                            filename=Path(report.report_txt).name,
                        )
                for result in report.tests:
                    if result.status in {"FAIL", "BLOCKED"} and result.screenshot:
                        image_path = Path(result.screenshot)
                        if image_path.exists():
                            with image_path.open("rb") as image:
                                await context.bot.send_photo(chat_id=chat_id, photo=image)
            except Exception:
                logger.exception("Test run failed")
                try:
                    await context.bot.send_message(
                        chat_id=chat_id,
                        text="The test run stopped unexpectedly. Check the local tester log.",
                    )
                except Exception:
                    logger.exception("Could not send failure message")
            finally:
                _active_task = None
                _cancel_event = None
                _progress_state = "No test run is active."

        _active_task = asyncio.create_task(execute(), name="shop-management-test-run")
        await message.reply_text(
            "Run started. The visible browser will open; sign in manually if needed. "
            "The tester waits 30 seconds before checking the Dashboard."
        )


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _guard(update):
        return
    await update.effective_message.reply_text(
        "Shop Management full UI tester. It creates uniquely named test records, "
        "runs the supported workflows, checks stock and balances, and sends a report.\n"
        "You sign in manually; it never types your password.\n"
        "Commands: /start or /run starts, /status reports progress, /stop requests cancellation."
    )
    await _begin(update, context)


async def run_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await _begin(update, context)


async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _guard(update):
        return
    if _active_task and not _active_task.done():
        await update.effective_message.reply_text(f"Run active. {_progress_state}")
    else:
        await update.effective_message.reply_text("No test run is active.")


async def stop_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await _guard(update):
        return
    if _active_task and not _active_task.done() and _cancel_event:
        _cancel_event.set()
        await update.effective_message.reply_text(
            "Cancellation requested. The current browser action will finish before the runner stops."
        )
    else:
        await update.effective_message.reply_text("No test run is active.")


def _acquire_process_lock():
    lock_dir = TESTER_DIR / "state"
    lock_dir.mkdir(parents=True, exist_ok=True)
    stream = (lock_dir / "bot.lock").open("a+b")
    stream.seek(0)
    if os.name == "nt":
        import msvcrt
        try:
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            stream.close()
            raise SystemExit("Another tester bot process is already running.")
    else:
        import fcntl
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            stream.close()
            raise SystemExit("Another tester bot process is already running.")
    return stream


def main() -> None:
    token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        raise SystemExit("Set TELEGRAM_BOT_TOKEN in tester/.env before starting the bot.")
    if not (
        os.getenv("ALLOWED_TELEGRAM_USER_ID", "").strip()
        or os.getenv("ALLOWED_TELEGRAM_CHAT_ID", "").strip()
    ):
        raise SystemExit(
            "Set ALLOWED_TELEGRAM_USER_ID or ALLOWED_TELEGRAM_CHAT_ID in tester/.env "
            "before starting the bot."
        )
    from telegram import Update
    lock = _acquire_process_lock()
    try:
        application = Application.builder().token(token).build()
        application.add_handler(CommandHandler("start", start_command))
        application.add_handler(CommandHandler("run", run_command))
        application.add_handler(CommandHandler("status", status_command))
        application.add_handler(CommandHandler("stop", stop_command))
        application.run_polling(allowed_updates=Update.ALL_TYPES)
    finally:
        lock.close()


if __name__ == "__main__":
    main()
