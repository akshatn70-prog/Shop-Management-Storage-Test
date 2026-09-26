# Shop Management

A mobile-friendly online, realtime shop stock and sales management PWA matching the supplied blueprint.

## Core workflow

Purchase/Stock Entry → Current Stock → Worker Sales → Automatic Stock Reduction → Revenue & Profit → Automatic Cash/UPI Summary → Reconciliation → History → 90-day Reports

## Roles

### Owner
- Add/edit products
- Add stock/purchases
- Set purchase and selling prices
- Configure whether below-cost and zero-price sales are allowed (both remain allowed by default)
- View stock, sales, profit, cash, UPI and reconciliation
- Manage worker profiles and roles
- Correct sales without deleting the historical record
- View automatic daily closing and day-end summaries
- Reports and history
- Audit trail
- Shop settings
- JSON backup/export (includes automatic daily snapshots)

### Worker
- View permitted stock
- Record sales during the day
- View automatic day-end and daily closing totals derived from recorded sales
- View their history information
- Cannot directly change stock, purchase prices, another worker's closing, finalized records, or delete sales

## Product and unit model

- Piece/count products use pieces as the base unit.
- Weight products use **grams internally**.
- The interface accepts grams or kilograms.
- Selling 750 g from a product priced at ₹50/kg calculates ₹37.50 and deducts 750 g.
- Purchase price and selling price are stored per piece or per kg as appropriate.

## Sales

The active app workflow records each sale immediately. Stock, revenue, cost, gross profit, Cash/UPI and the automatic day-end/daily-closing views are derived from those recorded sales. Legacy day-end/closing RPCs remain database-compatible for existing installations, but the current UI does not require duplicate worker submission or owner confirmation.

Mistakes are corrected by **voiding** a sale with a reason and restoring its stock. Historical rows are retained.

## Reconciliation and closing

- Expected sales are calculated from active recorded sales.
- Cash + UPI is compared with expected sales.
- UI shows \`MATCHED\`, \`SHORT ₹x\`, or \`EXTRA ₹x\`.
- The current UI calculates day-end and daily closing automatically from recorded sales.
- No duplicate cash/UPI entry or owner confirmation is required in the current flow.
- Historical legacy closing records remain visible.
- Clear All intentionally removes sales, purchases, closings and their historical audit entries, but leaves a permanent audit entry for the Clear All action.

## Reports

- Daily: sales, profit, purchases, cash, UPI, reconciliation and items sold.
- Weekly: sales, profit, quantities and best-selling products.
- Monthly: revenue, profit, purchases, cash, UPI and worker activity.
- History includes sales and daily closings.
- Owner audit history records important changes.

## Cart, Creditors & Daily Summary

- Workers can build an unlimited multi-item cart without changing stock or accounting until final confirmation.
- Cart items support edit/delete, quantity/unit changes, and selling-price changes only when the Owner enables **Workers can modify selling price**.
- Final cart confirmation is atomic: stock, sales, payment and credit ledger entries are committed together.
- Payment options are Cash, UPI, Cash + UPI, or Credit. Credit is kept separate from collected Cash/UPI and does not inflate revenue or profit when a later payment is received.
- Creditors are shared between Owner and Worker. Each creditor has an auditable ledger with credit sales and partial/full Cash/UPI collections.
- Daily Summary separates sales revenue, sales Cash/UPI, credit sales, and credit collections.
- Daily Summary can be downloaded as a TXT file. On Android, the app writes the file to the accessible Downloads folder where Android permits.

The customer SQL download is a single consolidated database setup. It includes the current sales, cart, credit/debtor, returns, reports, worker permissions, security/RLS and verification functionality. Existing single-product sales and the `record_sale` RPC remain supported.

## Security

Supabase Auth handles accounts. New accounts start as workers. The database uses Row Level Security and database functions for protected operations.

Important rules are enforced in PostgreSQL, not only by hiding buttons in the UI:
- Direct sale inserts are blocked; sales go through the atomic sale function.
- Stock is locked during a sale transaction.
- Workers cannot directly alter products or stock.
- Sales cannot be deleted.
- Finalized closings are protected.
- Owner-only correction and purchase operations are database-checked.
- Legacy approval/locking functions remain protected for existing closing records.
- At least one active owner is required.
- Below-cost and zero-price sales remain allowed by default, preserving the current sale workflow; owners can disable either rule in Settings.
- Direct purchase-row inserts are blocked; stock changes use protected operations.
- Automatic daily snapshots are persisted separately from the live dashboard.

## Supabase setup

1. Create a Supabase project.
2. Run \`supabase/schema.sql\` in the SQL Editor.
3. For an existing project, apply the SQL files in `supabase/migrations/` in timestamp order. For a fresh project, `supabase/schema.sql` already contains the current structure.
4. Create the first account from the app.
5. Promote that first account to owner in SQL:

\`\`\`sql
update public.profiles
set role = 'owner', is_active = true
where email = 'your-email@example.com';
\`\`\`

6. Configure:
   - \`VITE_SUPABASE_URL\`
   - \`VITE_SUPABASE_PUBLISHABLE_KEY\`
   - Supabase Auth Site URL = your deployed Render URL
   - Supabase Auth Redirect URLs = your deployed Render URL and local development URL when used
7. Run \`npm install\`
8. Run \`npm run dev\`

Do **not** put a Supabase service-role/secret key in the frontend.

## Deployment

The repository includes \`render.yaml\` for a free Render static-site deployment. Add the two Vite environment variables to the Render service before deploying.

The application is a static PWA frontend, so the database remains in Supabase rather than on the hosting server.

## Development checks

- \`npm run build\` validates the TypeScript/Vite application.
- \`.github/workflows/app-build.yml\` runs the application build on pushes and pull requests.
- \`supabase/tests/schema_test.sql\` contains database structure/RLS checks for Supabase CLI testing.
- \`.github/workflows/database-checks.yml\` parses the PostgreSQL schema and performs static safety checks in GitHub Actions. The pgTAP file is ready for `supabase test db` when a Supabase project/CLI environment is connected.

## Free-tier design

The app avoids images, videos and unnecessary files in the database. Business data is relational text/numeric data only, which keeps the database lightweight for a small shop.

## Files

- \`src/main.ts\` — application logic and UI
- \`src/styles.css\` — responsive mobile/desktop UI
- \`supabase/schema.sql\` — database, functions, RLS and realtime configuration
- \`supabase/tests/schema_test.sql\` — database checks
- \`manifest.webmanifest\` — PWA metadata
- \`public/sw.js\` — PWA caching shell
- \`render.yaml\` — free static deployment configuration


## Dashboard reset and reports

- Owner dashboard tracks the current business day using the shop timezone and the configurable **Dashboard reset time** in Settings.
- When the reset time is reached, the dashboard starts a new business-day period automatically; previous days remain in History and Reports.
- Reports include Daily, Weekly, Monthly and 90 Days views. The Reports panel also shows a date-wise 90-day table with transactions, revenue, profit, cash, UPI and reconciliation.
- The reset time is a shop setting (default `00:00`) and does not delete any sales data.


## Android builds

- Pushes to `main` automatically build an Android debug APK with the Supabase Vite secrets supplied through GitHub Actions repository secrets.
