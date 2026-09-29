# Shop Management UI tester

This tester controls the deployed web app through its visible UI using Playwright.
It creates uniquely named records for each run, verifies the resulting stock,
balances, transaction history, and reports, then sends a run summary and failure
screenshots through Telegram.

It never enters the user's password, writes directly to Supabase, presses
“Clear All”, or deletes unrelated shop data. Test products/accounts are named
RUN-<timestamp>-<case>. They remain in the dedicated test shop for inspection.
One unused, zero-stock product is created and deleted to exercise that feature.

## One-time configuration

Keep tester/.env private and uncommitted. The bot token is already read from
that file; do not paste it into Telegram or reports. Fill in:

~~~dotenv
APP_URL=https://shop-management-storage-test.onrender.com/
TELEGRAM_BOT_TOKEN=your_existing_bot_token
ALLOWED_TELEGRAM_USER_ID=your_numeric_telegram_user_id
WAIT_AFTER_OPEN_MS=30000
ENABLE_TEST_DATA_WRITES=true
TEST_SHOP_CONFIRMATION=I_CONFIRM_THIS_IS_A_DEDICATED_TEST_SHOP
TEST_PROFILE_DIR=tester/state/browser-profile
REPORT_DIR=tester/reports
SCREENSHOT_DIR=tester/screenshots
~~~

The tester currently requires an explicit Telegram allowlist and a one-time
write acknowledgement. Set these only after checking that the logged-in owner
account points to the dedicated test shop/Supabase project. The app can use a
different Supabase project than the Render hostname, so the URL alone is not
proof that its data is disposable. To find your numeric Telegram ID, use a
trusted Telegram ID lookup bot. Do not allowlist a public group.

If writes are not enabled, the bot still opens the app, waits, and checks the
Dashboard, then marks the data suites BLOCKED without creating anything.

## Install and start on Windows

Open PowerShell in the project root:

~~~powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r tester\requirements.txt
.\.venv\Scripts\python.exe -m playwright install chromium
.\.venv\Scripts\python.exe tester\bot.py
~~~

Do not start a second bot process with the same token; a process lock prevents
two copies from polling at once. Send /start to your bot. The visible browser
opens on this computer. Sign in manually if needed. After 30 seconds the tester
checks for the owner Dashboard and begins. From then on, leave the browser alone.

Commands:

- /start explains the tester and starts a run if none is active.
- /run starts a run.
- /status shows the latest suite/check progress.
- /stop requests stopping after the current browser action.

## What the test run covers

The run creates its own piece product, kg-priced weight product, gram-priced
weight product, customer creditor, and supplier debtor. It exercises:

- Product creation with opening stock, price editing, and deletion of an unused
  zero-stock test product.
- Purchases paid by cash, UPI, split cash/UPI, credit, and pre-stock recording.
- Weight stock conversions for kg and grams.
- Single sales and two-product carts using cash, UPI, split, credit, and
  credit-plus-cash-plus-UPI.
- Cart item editing, cart transaction grouping, payment total arithmetic, and
  rejection of invalid stock and payment splits.
- Cash, UPI, and split creditor receipts and debtor payments.
- Purchase and sale returns with cash, UPI, and account balance adjustments.
- Legacy single-sale void and full cart void, including the assumed transaction
  RPC, stock restoration, credit reversal, and duplicate-click guard.
- Sales/purchase history, date selection, Dashboard, Today Stats, Reports, and
  creditor/debtor histories.
- Vertical and horizontal scrolling to controls and report columns after the
  layout shifts.

The suite tests every payment option and defined workflow above. It does not
try every possible numeric value; that set is unbounded. It uses small known
amounts and a 0.01 currency tolerance. Some current app actions do not display a
success toast; the tester reports those as feedback failures even if stock or
history changed, so functional failures remain distinguishable from missing UI
confirmation.

Cart void expects the deployed database function:

~~~text
void_sale_transaction(p_transaction_id uuid, p_reason text) returns void
~~~

Legacy standalone sales continue to use void_sale(p_sale_id uuid, p_reason
text). If the cart RPC is missing, that case is reported BLOCKED with the
function name. The tester does not edit or apply SQL migrations.

## Output

Each run writes a readable TXT report and full JSON report under
tester/reports/. Failure screenshots go under tester/screenshots/; the Telegram
bot sends the TXT and failure screenshots while the JSON stays local. Browser
login state is stored under tester/state/. These paths are ignored by Git.
