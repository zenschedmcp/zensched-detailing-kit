# ZenSched Mobile-Detailing Reference Kit

A copy-pasteable setup for a 1–5 van mobile car-detailing shop that wants an AI assistant to run driveway bookings, recurring fleet lots, GPS-verified arrival, a Job Report with before/after photos, add-ons and on-site upsells, receivables, and contractor payouts. ZenSched handles the phone app, the GPS check-in at each driveway or lot, the event and shift per job (or the rolling event per fleet lot), and the Job Report. A small local database on your computer holds your customers, vehicles, sites, the fleet weekday template, jobs, invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste a booking text ("Priya wants a full detail Saturday at 10"), ask "schedule the Cascade vans this week", "close out today", "invoice Cascade", "who owes me money", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## What this kit is not — read this first

**What it is:** a way to get every job onto a phone from a spoken or pasted booking, prove GPS-verified arrival at the driveway or lot, record what was done (package, optional paint meter, before/after photos, add-ons, upsell), and turn those records into invoices and contractor payouts.

**What it is not:**

- **Not a shop management suite.** No bay calendar, no parts inventory, no ceramic-warranty register, no customer portal. If you need those, this kit is the dispatch-and-proof layer next to whatever you already use.
- **Not a signed customer acceptance.** The Job Report has no signature pad, on purpose: on ZenSched a signature field replaces the Submit button, and a signature on an ops form is not a customer sign-off on paint work. After photos are the proof.
- **Not a paint-thickness certificate or coating warranty.** The paint-meter field is a number the detailer types from their own gauge. It is not calibrated, verified, or certified by ZenSched, and it is not a condition report or a manufacturer's coating warranty. Do not present it to a customer as one.
- **ZenSched never receives plates, VINs, gate codes, or retail customers' names.** Those live only in the local database. ZenSched sees a site label (`Maple Ave - University Place` for a driveway, `Cascade Plumbing - Kent` for a business lot), the street address for the GPS pin, an event title made of the package and job number (or `Detailing - <lot>` for a fleet), and the Job Report.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof, before/after photos, and receivables you can chase, read on.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per site, cached locally so a fleet lot is created once; the check-in radius is a **policy** setting)
- Workers (you, in solo mode; you plus contractors, each with the mobile app)
- Events — two shapes: one single-day event per on-demand job, or one rolling ≤60-day event per fleet lot
- Shifts (one per job: the work window, with a push notification)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Job Report form (package, optional paint meter, before photos max 3, after photos max 3 required, add-ons, upsell amount, notes) and every submission

**Local SQLite database (`detail-ops.db`, on your computer):**

- Customers: retail, fleet, dealership, rental, with payment terms and a default trip fee
- Sites: every driveway and lot, normalized, with its ZenSched location id and access notes — **access notes never leave your computer**
- Vehicles: year / make / model / label, plate and VIN — **never leave your computer**
- Packages (exterior, interior, full, ceramic, paint correction, fleet wash) and the fleet weekday template
- Detailers, including contractor split; your own jobs never generate payouts
- Jobs: the booking, amounts, outcome, ZenSched event/shift/submission ids, GPS stamps copied once, Job Report summary
- Invoices per customer with aging; payouts per contractor per job
- Your settings (timezone, default detailer, invoice prefix, Job Report form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on time", "what did we do to Van 3", and "who owes me" without paying to re-read records.

### Privacy note

Plates, VINs, gate codes, and garage-opener locations live only in `vehicles.plate`, `vehicles.vin`, `sites.access_notes`, and `sites.parking_notes`; retail customers' names and phone numbers live only in `customers`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons. A driveway's `site_label` is street + city, never the homeowner's name; a fleet lot may carry the business name. You are still responsible for your own privacy obligations on the local database; this kit narrows what a third party sees.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `detail-ops.db` on your computer.

When you book a driveway job, the AI adds the customer if new, caches the address, saves job `J-2026-0001`, creates a single-day event and a shift with the Job Report attached, and confirms in one line. When you say "schedule the Cascade vans", it expands the Tuesday template into one job per van, puts those shifts on the lot's rolling 60-day event, and staggers the times. You check in at the pin (GPS-verified), work the car, check out, and fill in the Job Report — after photos required, paint meter if you took one, add-ons and any upsell. "Close out today" pulls verified arrival and the reports, updates each job, and tells you what is receivable. "Invoice Cascade" writes a plain-text invoice under their terms. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor works too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\detail-ops`
- Mac: `/Users/yourname/detail-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain plates, VINs, and gate codes; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\detail-ops.db` (Windows) or `/detail-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "detail-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/detail-ops/detail-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\detail-ops\\detail-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Mobile Detail" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my detail-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run the statements and confirm the tables exist. The `detail-ops.db` file now exists in your folder with default settings (90-minute jobs, net 14, seeded packages) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 detail-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Harbor Shine Mobile Detail in Tacoma, Washington, Pacific time. It's just me, Jordan Hale, jordan@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the detailer on the phone; $0.25, one time), creates the Job Report form on ZenSched (free), and saves the form id so every job gets it automatically. Then say "add my contractor Luis Mora, luis@example.com, I pay him $80 a job" if you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's policy, not per address, and with geofencing on it raises anything under 100 m to about 91 m (300 ft). For apartment garages and fleet lots, ask the AI to "set the check-in radius to 200 m" (`policy_update`), or to move the pin onto the lot entrance (`location_update`, free; the site cache keeps it). Do **not** ask it to widen the radius "on that location."

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached site), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading a Job Report ($0.15 when it has photos — after photos are required, so assume that; each record is billed once, ever). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

A job at a new driveway costs $0.03 + $0.20 + $0.15 = **$0.38**; a job at a cached fleet lot costs **$0.35**. Twenty jobs a week is about $28/month. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- "Priya Shah, full detail Saturday 10 am, 4412 Maple Ave University Place, 2019 CR-V. Book it."
- "Add Cascade Plumbing as a fleet, Kent lot, three vans, every Tuesday 8 am fleet wash at $25."
- "Schedule the Cascade vans this week."
- "What's today?" / "What's this week?"
- "Was I on time at Priya's?"
- "Close out today. Priya: pet hair $40, she added wax $25."
- "The CR-V no-showed. Get me the trip fee."
- "The 10 o'clock moved to 1." / "Move Van 2 to Thursday."
- "Cancel the ceramic; they owe a $50 late fee."
- "Invoice Cascade." / "Invoice everyone."
- "Who owes me money?"
- "Cascade paid INV-2026-0002."
- Contractor: "What do I owe Luis?" / "Paid Luis."

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Cascade" records the invoice in your database (number, date, due date under that customer's terms, total, which jobs with package / add-on / upsell) and the AI writes out a plain-text invoice you can paste into an email, with a line per job (job number, date, vehicle label, amounts). It does **not** generate a PDF, submit it for you, or collect payment. Invoices use the vehicle label ("Van 3", "2019 CR-V"), never the plate or VIN. When they pay, tell the AI and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (contractor mode)

Contractors are paid per job, not by the hour. Each sub has a split (`$80 flat` or `60%` of what the customer is billed for that job). When a sub's job is closed out, a payout row is created; "what do I owe Luis" lists his unpaid jobs and the total. Your own jobs never generate payouts. The kit does not calculate taxes, issue 1099s, or pay anyone. If you also want an hours record, ZenSched's `timesheet_export(mode="hours")` is free.

## Mobile app for detailers

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [TestFlight](https://testflight.apple.com/join/Wp51m5Yq)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your jobs appear as they are booked. Each one shows the address and time; you check in on arrival (GPS-verified), check out when you leave, and fill in the Job Report — after photos are required. Contractors get the same email when you add them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `detail-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to -08:00 in settings" (Pacific is -07:00 in summer, -08:00 in winter) |
| Job not on my phone | Booked locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's jobs on my phone"; the AI finishes the booking steps |
| Check-in not GPS-verified at a garage / fleet lot | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`, **not** on the location), or "move the pin to the lot entrance" (`location_update`, free) |
| App would not let me check in 15 minutes early | Early check-in window too small | "Allow check-in 20 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Job Report not on the phone | Form was never assigned to that job's event | "Attach the Job Report to J-2026-0004" (`form_assign(form_id, event_id=...)`). It installs on the existing shift; do not cancel and recreate it |
| Fleet shifts fail a couple of months out | The lot's 60-day ZenSched event has expired | "Renew the Cascade event"; the AI rolls a new window |
| On-demand job moved to another day fails on `shift_update` | On-demand events are single-day | The AI cancels the shift and creates a new job (`rescheduled_from`) with its own event |
| AI refuses to put a plate or gate code in ZenSched | Working as intended | Give it to the detailer directly |
| Same lot geocoded twice | Address typed differently | Tell the AI it is the same site; it reuses the `sites` row |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for customers, vehicles, sites, the fleet template, jobs (including plates / VINs / access notes), billing, and payouts; each side stores only the other's integer IDs, plus a per-job summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (plate / VIN / access columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rule 5.

**Data model decisions.**

- **Hybrid of the notary (one-off) and pet-care (recurring) kits.** `jobs` is the driving table for both shapes. On-demand retail is one job → one single-day `event_create` (`idempotency_key="event-job-{job_id}"`) → one `shift_create` (`shift-job-{job_id}`), with `form_assign` in between. Recurring fleet is a `job_schedule` weekday mask (Monday first) expanded by `fleet_due_this_week` into job rows, then shifts on a **per-site** event rolled every ≤60 days (`event-site-{site_id}-{YYYYMMDD}`). Never one event per van.
- **`sites.event_mode`** is `one_off` (driveway / shop retail) or `rolling` (fleet lot / dealership). `jobs_upcoming.event_needs_roll` is 1 only for rolling sites whose `event_valid_until` is missing or earlier than the job date. `events_expiring` lists rolling sites with an active schedule whose window ends within 14 days.
- **`sites` is an address de-dup cache per customer.** `UNIQUE (customer_id, normalized_address)`; the agent normalizes (lowercase, strip `,` `.` `#`, collapse whitespace, include city/state/zip) and looks it up before any `location_create`. Two customers may share an address string (an apartment garage). `site_label` is the only name sent to ZenSched: `<street> - <city>` for a retail driveway (no house number, no homeowner name), `<business> - <city> lot` for a fleet.
- **Customers → vehicles / sites → jobs.** A retail customer has a driveway site and one or more vehicles. A fleet customer has a lot and many vehicles pinned to it (`vehicles.site_id`). A job always has `site_id` (where you stand) and usually `vehicle_id` (what you work on).
- **`job_no`** is assigned by trigger as `J-{YYYY of scheduled_start}-{job_id:04d}` when left NULL. Invoice numbers are `{prefix}-{YYYY}-{invoice_id:04d}`.
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-12T10:00`, `CHECK`-constrained to reject a trailing offset or `Z`). Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer. `date('now')` would be UTC and would roll "today" over at 4–5 pm Pacific.
- **`billable_total` is computed in a view, not stored.** Snapshots on the job: `package_amount`, `addon_amount`, `upsell_amount`, `trip_fee`, `other_fee`, filled by `fill_job_defaults`. `billable_jobs`: `completed` → package + addon + upsell + other; `no_show` → trip; `cancelled` → `other_fee` only; else 0. Receivables, the invoice `INSERT ... SELECT`, and `fill_payout_amount` all read that view.
- **`source` is `recurring` whenever `schedule_id` is set** (trigger), else `on_demand`. `fleet_due_this_week` omits dates that already have a live (not cancelled / rescheduled) job for that schedule row, so "schedule the week" is safe to re-run.
- **No signature field on the form.** After photos are `required` with `max_images: 3`; before photos are optional, also max 3. Paint meter is an optional `number`. Add-ons are `multi_select` (keys only — the owner prices `addon_amount`). Upsell is `currency`. A submission with photos bills $0.15 instead of $0.05.
- **GPS stamps are copied once** onto the job so "was I on time" and `no_show_evidence.minutes_on_site` are answered locally.
- **Solo mode is the default; contractor mode is additive.** The owner is invited as a worker and stored on `detailers` with `is_owner = 1`; `settings.default_detailer_id` points at that row. `payouts_due` / `payouts_missing` exclude the owner.
- **The check-in radius is policy-enforced.** `location_create(checkin_radius_m=...)` is informational; widen with `policy_update(0, '{"checkin_radius_m": N}')`. Fleet lots should start at 150–300 m.
- `jobs.zensched_shift_id`, `detailers.zensched_worker_id`, `payouts.job_id`, and `sites(customer_id, normalized_address)` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a customer cascades to sites, vehicles, schedules, jobs, invoices, and payouts; `sites` is `ON DELETE RESTRICT` while jobs reference it; deleting a vehicle sets `jobs.vehicle_id` NULL; deleting a detailer sets `jobs.detailer_id` NULL and removes their payouts.

**Job Report form.** Created once with `form_create(title, fields_json, idempotency_key="form-job-report")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's `_validate_fields`. Every field carries an explicit `identifier` so submission `data` keys are stable (`package`, `paint_meter`, `photo_before`, `photo_after`, `addons`, `upsell`, `notes`; section `sec_job`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters); every option here is well under 30 characters. Attaching is `form_assign(form_id, event_id=...)` per event; it also installs the form on shifts that already exist on that event, so a forgotten assignment never requires cancelling a shift.

**Idempotency keys.** Deterministic, derived from local IDs:

- location: `loc-site-{site_id}`
- event (on-demand): `event-job-{job_id}`
- event (fleet roll): `event-site-{site_id}-{YYYYMMDD window start}`
- shift: `shift-job-{job_id}` for the first shift; every later shift on the same job (detailer swap, fleet reschedule to another day) appends `-2`, `-3`, ... so a cancelled shift's key is never reused within ZenSched's 24-hour replay window
- assignment: `assign-job-report-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-job-report`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per job.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset`, never `Z`. The views build these strings so the agent does not have to.

**Metered reads.** `form_submissions(form_id, event_id=...)` is exact for on-demand (one event per job). Fleet jobs share a site event, so match by time / worker or use `form_export` for the day. Both bill $0.15 per submission with photos, once per submission ever. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var pointing at `detail-ops.db`). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite.

**Schema test.** The schema was verified by splitting the file into its 64 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 10 tables, 10 views, and 10 triggers present; every view on an empty database; 9 settings and 6 package seed rows not duplicated; `packages` codes; `number_job` (`J-YYYY-0001`, explicit number kept); `fill_job_defaults` (duration from the package and following a 90-minute ceramic, detailer from `default_detailer_id`, `package_amount` from the list else an explicit 199 kept, extras 0, `trip_fee` from the customer — $25 retail / $0 fleet); `source` flipped to `recurring` when `schedule_id` is set; `jobs_today` / `jobs_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 150/90-minute durations, `needs_location` when the site has no location id, `needs_shift`, the three idempotency keys, `zensched_event_title` = package + number on `one_off` and `Detailing - <site_label>` on `rolling` with no plate in either name, `zensched_location_name` from `site_label`, worker id from the default detailer, 7-day window bounds with +6 included and +7 excluded, cancelled excluded); `event_needs_roll` flipping exactly when a rolling site's `event_valid_until` is before the job date, and staying 0 on `one_off`; `fleet_due_this_week` Tuesday mask (`0100000`) expanding three staggered vans, dropping a van after a live job is inserted, returning it when that job is cancelled, omitting inactive schedules; `events_expiring` (rolling + schedule + window ≤ +14, one_off excluded); `billable_jobs` for completed (240 = package + addon + upsell), no-show (25 = trip only), cancelled (`other_fee` only), and confirmed (0); `receivables_by_customer` totals, counts, and terms, and the drop-off after invoicing; `no_show_evidence` joining shift id, `minutes_on_site` (39), billable, and customer; invoice numbering, total, due date = +14 days from the customer's terms, `line_items` JSON; `invoices_outstanding` aging buckets `90+` / `60` / `30` / `current` with `days_past_due` and paid excluded; `payouts_missing`; `payouts_due` math for flat (80) and percent (60% of 240 = 144), `needs_amount` for a detailer without a split, owner exclusion, paid rows dropping out; `rescheduled_from`; every `CHECK` (customer type, site kind, event mode, source, status, payout type, `scheduled_start` format with offset and `Z` rejected, duration range, weekdays, preferred start); `UNIQUE` on `sites(customer_id, normalized_address)` while two customers may share an address, `detailers.zensched_worker_id`, `jobs.zensched_shift_id`, and `payouts.job_id`; foreign keys rejecting an unknown customer, `RESTRICT` on sites, `SET NULL` on vehicle and detailer delete, cascade on customer delete (no jobs) and on detailer payouts; `updated_at`; integer types on ZenSched ID columns. Form payload validated against `_validate_fields` (8 fields, no signature, package and after-photos required, paint meter and before-photos optional, max 3 images each, SKILL.md byte-identical to example-workflow.md, every option key ≤ 30 characters). 243 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
