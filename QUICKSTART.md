# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop (or Cursor) and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "What this kit is not" section of `README.md`. Short version: plates, VINs, gate codes, and your retail customers' names stay on your computer; ZenSched only ever sees a site label (street + city, or a fleet's business name), an address, and a Job Report with before/after photos. No customer signature pad, and the paint-meter field is a note from your own gauge, not a certified thickness report.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\detail-ops` (Windows) or `/Users/yourname/detail-ops` (Mac). Note the full path. It will hold plates, VINs, and gate codes, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\detail-ops\\detail-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Mobile Detail". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my detail-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Harbor Shine Mobile Detail in Tacoma, Washington, Pacific time. It's just me, Jordan Hale, jordan@example.com, 253-555-0100. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the detailer on the phone), and calls `form_create` once (free) to build the Job Report you fill in after each car: package, optional paint meter, before photos (max 3), after photos (max 3, required), add-ons, upsell amount, notes. No signature pad. It stores the form id so every job gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS TestFlight](https://testflight.apple.com/join/Wp51m5Yq)).

Optional but recommended: "Allow check-in 15 minutes early and set the radius to 200 m." Apartment garages and fleet lots sit far from the street pin. Widen the radius with `policy_update`, not on the location.

Contractor: "Add Luis Mora, luis@example.com, I pay him $80 a job."

## 6. Book your first driveway job

> Priya Shah, full detail Saturday Sep 12 at 10, 4412 Maple Ave, University Place WA 98466. 2019 Honda CR-V white, plate ABC1234. Gate 4412. Book it.

Behind the scenes the AI adds Priya as retail, caches the driveway as a one-off site, saves the CR-V (plate local only), inserts `J-2026-0001`, creates a single-day `event_create` titled `Full detail J-2026-0001`, attaches the Job Report with `form_assign`, and creates the `shift_create` for 10:00–12:30. You get one line back with the job number and the price.

## 7. Add a fleet lot

> Add Cascade Plumbing as a fleet account, net 30. Their Kent lot is 8804 84th Ave S, Kent 98032. Three vans: Van 1 Ford Transit, Van 2 Chevy Express, Van 3 Ram Promaster. Every Tuesday 8 am, fleet wash $25 each. Gate 8804.

The AI marks the site `event_mode = rolling`, creates one location, rolls a 60-day event titled `Detailing - Cascade Plumbing - Kent`, and writes three `job_schedule` rows (`weekdays = 0100000`). It does not put this week's vans on the phone until you say so.

> Schedule the Cascade vans this week.

One job + one shift per van on the lot event, staggered 8:00 / 8:20 / 8:40.

## 8. The job

Your phone shows the shift. At the driveway or lot, **Check in** (GPS-verified). Work the car. **Check out**. Open the **Job Report**: Package, paint meter if you took one, before photos (optional), **after photos required**, add-ons, upsell amount. Submit.

## 9. Close out

> Close out today. Priya: pet hair $40, she added wax $25.

The AI pulls your GPS-verified arrival and departure (free), reads the Job Report (metered, so it tells you the cost first, about $0.15 with the photos), updates the job, and tells you what is now receivable.

> Was I on time at Priya's?

Answered from the local record, free: scheduled vs GPS-verified check-in, distance from the pin.

> The CR-V no-showed. Get me the trip fee.

Marks the job a no-show (trip fee stays billable) and drafts the note with your GPS-verified arrival and minutes waited.

## 10. Money

> Invoice Priya. Invoice Cascade.

A plain-text invoice under each customer's terms with one line per job (your number, date, vehicle label, package / add-on / upsell). No plates or VINs.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Cascade paid INV-2026-0002.

Marks it paid.

Contractor: "What do I owe Luis?" lists his unpaid jobs and total; "paid Luis" marks them.

## What next

- `README.md` for the full explanation, the privacy boundary, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
