# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Harbor Shine Mobile Detail**, a solo-plus-one shop (Jordan Hale, owner; later Luis as a contractor) in Tacoma, Washington, Pacific time (`-07:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: plates, VINs, gate codes. ZenSched sees `Shah - Maple Ave`, a street address, `Full detail J-2026-0001`, `Detailing - Cascade Plumbing - Kent`, and a Job Report.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Mobile Detail, timezone_offset = -05:00,
    default_detailer_id = NULL, default_job_minutes = 90,
    default_travel_buffer_minutes = 20, invoice_due_days = 14, invoice_prefix = INV,
    job_report_form_id = NULL, event_window_days = 60
sqlite_query:   SELECT * FROM jobs_today;            → (none)
sqlite_query:   SELECT * FROM fleet_due_this_week;   → (none)
```

## "We're Harbor Shine Mobile Detail in Tacoma, Washington, Pacific time. It's just me, Jordan Hale, jordan@harborshine.example, 253-555-0100. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'Harbor Shine Mobile Detail' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '-07:00' WHERE key = 'timezone_offset';
```

Agent (first metered call this session, rule 10):

> Saved. Since you're the detailer on the phone, I need to invite you to ZenSched as a worker so your jobs show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "jordan@harborshine.example"
  first_name: "Jordan"
  last_name: "Hale"
  idempotency_key: "worker-jordan@harborshine.example"
  → worker_id: 701, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO detailers (detailer_name, email, phone, zensched_worker_id, is_owner)
  VALUES ('Jordan Hale', 'jordan@harborshine.example', '253-555-0100', 701, 1);
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_detailer_id';
```

> You're invited; install the app from the email. Next, the Job Report: it's free to create and every job comes back with the package, an optional paint meter, before/after photos (after is required), add-ons, and any upsell. No signature pad. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Job Report"
  idempotency_key: "form-job-report"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Job report", "identifier": "sec_job",
   "text": "Fill this in before you leave. After photos are required. This is an ops record, not a customer signature."},
  {"type": "select", "label": "Package", "identifier": "package", "required": true,
   "options": ["Exterior wash", "Interior", "Full detail", "Ceramic coat", "Paint correction", "Fleet wash"]},
  {"type": "number", "label": "Paint meter (mils)", "identifier": "paint_meter"},
  {"type": "photo", "label": "Before photos", "identifier": "photo_before", "max_images": 3},
  {"type": "photo", "label": "After photos", "identifier": "photo_after", "max_images": 3, "required": true},
  {"type": "multi_select", "label": "Add-ons", "identifier": "addons",
   "options": ["Pet hair", "Engine bay", "Headlight restore", "Odor treatment", "Clay bar", "Wax"]},
  {"type": "currency", "label": "Upsell amount", "identifier": "upsell"},
  {"type": "textarea", "label": "Notes", "identifier": "notes"}
]
```

```
  → form_id: 501, fields: [ ...8 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '501' WHERE key = 'job_report_form_id';
```

> Job Report created. I'll attach it to every job automatically. One policy question: apartment garages and fleet lots sit far from the street pin — want me to allow 15-minute early check-in and set the radius to 200 m?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 200, \"checkin_slack_min\": 15, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## "Priya Shah wants a full detail Saturday Sep 12 at 10 at 4412 Maple Ave, University Place WA 98466. 2019 Honda CR-V, white, plate ABC1234. Gate 4412. Book it."

The agent parses: retail customer, full package, Saturday 10:00, driveway, CR-V, plate and gate **local only**.

```
sqlite_query: SELECT package_id, default_minutes, price FROM packages WHERE code = 'full';  → 3, 150, 175.00

sqlite_execute:
  INSERT INTO customers (customer_name, customer_type, contact_name, payment_terms_days, default_trip_fee)
  VALUES ('Priya Shah', 'retail', 'Priya Shah', 14, 25);
  → lastInsertRowid = 1

sqlite_query: SELECT site_id, zensched_location_id FROM sites
              WHERE customer_id = 1 AND normalized_address = '4412 maple ave university place wa 98466';
  → (none)

sqlite_execute:
  INSERT INTO sites (customer_id, site_label, site_kind, event_mode, normalized_address, address, city, state, zip, access_notes)
  VALUES (1, 'Shah - Maple Ave', 'driveway', 'one_off', '4412 maple ave university place wa 98466',
          '4412 Maple Ave', 'University Place', 'WA', '98466', 'Gate 4412');
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO vehicles (customer_id, site_id, year, make, model, color, plate, vehicle_label)
  VALUES (1, 1, 2019, 'Honda', 'CR-V', 'white', 'ABC1234', '2019 CR-V');
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO jobs (customer_id, vehicle_id, site_id, package_id, source, scheduled_start, status)
  VALUES (1, 1, 1, 3, 'on_demand', '2026-09-12T10:00', 'confirmed');
  → lastInsertRowid = 1
  (triggers fill: job_no J-2026-0001, duration_minutes 150, detailer_id 1,
   package_amount 175, addon 0, upsell 0, trip_fee 25, other_fee 0)

sqlite_query:
  SELECT job_no, start_iso, end_iso, zensched_location_name, zensched_event_title, street_address,
         event_mode, needs_location, event_needs_roll, zensched_worker_id,
         loc_idempotency_key, event_idempotency_key, shift_idempotency_key
  FROM jobs_upcoming WHERE job_id = 1;
  → J-2026-0001 | 2026-09-12T10:00:00-07:00 | 2026-09-12T12:30:00-07:00
    | Shah - Maple Ave | Full detail J-2026-0001
    | 4412 Maple Ave, University Place, WA 98466 | one_off | needs_location 1 | event_needs_roll 0
    | worker 701 | loc-site-1 | event-job-1 | shift-job-1
```

> Putting this on ZenSched costs $0.03 to geocode the driveway; the job itself is about $0.35 in GPS check-in/out and reading the photo report ($0.38 total for a new address). OK to proceed for this and future jobs?

Owner: *"yes"*

```
location_create:
  name: "Shah - Maple Ave"
  street_address: "4412 Maple Ave, University Place, WA 98466"
  checkin_radius_m: 100
  idempotency_key: "loc-site-1"
  → location_id: 9201, lat: 47.2351, lng: -122.5460, pin_quality: "street",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE sites SET zensched_location_id = 9201 WHERE site_id = 1;

event_create:
  location_id: 9201
  title: "Full detail J-2026-0001"
  start_date: "2026-09-12"
  end_date:   "2026-09-12"
  idempotency_key: "event-job-1"
  → event_id: 8101

form_assign:
  form_id: 501
  event_id: 8101
  idempotency_key: "assign-job-report-8101"
  → status: "assigned", form_id: 501, event_id: 8101, policy_id: 0

shift_create:
  event_id: 8101
  worker_id: 701
  start: "2026-09-12T10:00:00-07:00"
  end:   "2026-09-12T12:30:00-07:00"
  idempotency_key: "shift-job-1"
  → shift_id: 99101, status: "scheduled", forms_installed: [501]

sqlite_execute: UPDATE jobs SET zensched_event_id = 8101, zensched_shift_id = 99101 WHERE job_id = 1;
```

Nothing about the plate, VIN, or gate code is in `name`, `title`, or `notes`.

> Booked **J-2026-0001**: full detail, Priya's 2019 CR-V, Sat Sep 12 10:00–12:30 at Maple Ave, University Place. $175, net 14. It's on your phone with the Job Report attached. Plate and gate code stay on your computer.

## "Add Cascade Plumbing as a fleet, net 30. Kent lot 8804 84th Ave S, Kent 98032. Three vans — Van 1 Ford Transit, Van 2 Chevy Express, Van 3 Ram Promaster. Every Tuesday 8 am, fleet wash $25. Gate 8804."

```
sqlite_query: SELECT package_id, default_minutes, price FROM packages WHERE code = 'fleet_wash';  → 6, 20, 25.00

sqlite_execute:
  INSERT INTO customers (customer_name, customer_type, contact_name, billing_email, payment_terms_days, default_trip_fee)
  VALUES ('Cascade Plumbing', 'fleet', 'Office', 'ap@cascadeplumbing.example', 30, 0);
  → lastInsertRowid = 2

sqlite_execute:
  INSERT INTO sites (customer_id, site_label, site_kind, event_mode, normalized_address, address, city, state, zip, access_notes)
  VALUES (2, 'Cascade Plumbing - Kent', 'lot', 'rolling', '8804 84th ave s kent wa 98032',
          '8804 84th Ave S', 'Kent', 'WA', '98032', 'Gate 8804. Park along the south fence.');
  → lastInsertRowid = 2

sqlite_execute: INSERT INTO vehicles (customer_id, site_id, make, model, vehicle_label)
                VALUES (2, 2, 'Ford', 'Transit', 'Van 1');     → 2
sqlite_execute: INSERT INTO vehicles (customer_id, site_id, make, model, vehicle_label)
                VALUES (2, 2, 'Chevy', 'Express', 'Van 2');    → 3
sqlite_execute: INSERT INTO vehicles (customer_id, site_id, make, model, vehicle_label)
                VALUES (2, 2, 'Ram', 'Promaster', 'Van 3');    → 4

sqlite_execute: INSERT INTO job_schedule (customer_id, site_id, vehicle_id, package_id, weekdays, preferred_start, start_date)
                VALUES (2, 2, 2, 6, '0100000', '08:00', '2026-09-08');   → 1
sqlite_execute: INSERT INTO job_schedule (customer_id, site_id, vehicle_id, package_id, weekdays, preferred_start, start_date)
                VALUES (2, 2, 3, 6, '0100000', '08:20', '2026-09-08');   → 2
sqlite_execute: INSERT INTO job_schedule (customer_id, site_id, vehicle_id, package_id, weekdays, preferred_start, start_date)
                VALUES (2, 2, 4, 6, '0100000', '08:40', '2026-09-08');   → 3
```

Staggered 20 minutes so one detailer can do them back-to-back. The agent does not re-ask about the $0.03 (already approved this session).

```
location_create:
  name: "Cascade Plumbing - Kent"
  street_address: "8804 84th Ave S, Kent, WA 98032"
  checkin_radius_m: 150
  idempotency_key: "loc-site-2"
  → location_id: 9202, pin_quality: "street"

sqlite_execute: UPDATE sites SET zensched_location_id = 9202 WHERE site_id = 2;

event_create:
  location_id: 9202
  title: "Detailing - Cascade Plumbing - Kent"
  start_date: "2026-09-08"
  end_date:   "2026-11-06"
  idempotency_key: "event-site-2-20260908"
  → event_id: 8201

form_assign:
  form_id: 501
  event_id: 8201
  idempotency_key: "assign-job-report-8201"

sqlite_execute: UPDATE sites SET zensched_event_id = 8201, event_valid_until = '2026-11-06' WHERE site_id = 2;
```

> Added Cascade Plumbing, Kent lot, 3 vans, Tuesday fleet wash $25 each, net 30. Rolling event through Nov 6. Gate code local only. Say "schedule the Cascade vans" when you want this week on the phone.

## "Schedule the Cascade vans this week."

Assuming "today" is Monday 2026-09-07, Tuesday the 8th is inside the 7-day window.

```
sqlite_query: SELECT * FROM fleet_due_this_week;
  → 2026-09-08 | sched 1 | Van 1 | 08:00 | fleet_wash | $25 | event_needs_roll 0 | worker 701
    2026-09-08 | sched 2 | Van 2 | 08:20 | fleet_wash | $25 | event_needs_roll 0 | worker 701
    2026-09-08 | sched 3 | Van 3 | 08:40 | fleet_wash | $25 | event_needs_roll 0 | worker 701

sqlite_execute: INSERT INTO jobs (customer_id, vehicle_id, site_id, package_id, schedule_id, scheduled_start, status)
                VALUES (2, 2, 2, 6, 1, '2026-09-08T08:00', 'confirmed');   → 2  (J-2026-0002, source recurring)
sqlite_execute: INSERT INTO jobs (customer_id, vehicle_id, site_id, package_id, schedule_id, scheduled_start, status)
                VALUES (2, 3, 2, 6, 2, '2026-09-08T08:20', 'confirmed');   → 3  (J-2026-0003)
sqlite_execute: INSERT INTO jobs (customer_id, vehicle_id, site_id, package_id, schedule_id, scheduled_start, status)
                VALUES (2, 4, 2, 6, 3, '2026-09-08T08:40', 'confirmed');   → 4  (J-2026-0004)

shift_create: event_id 8201, worker_id 701, start 2026-09-08T08:00:00-07:00, end 2026-09-08T08:20:00-07:00,
              idempotency_key "shift-job-2"   → 99102
shift_create: event_id 8201, worker_id 701, start 2026-09-08T08:20:00-07:00, end 2026-09-08T08:40:00-07:00,
              idempotency_key "shift-job-3"   → 99103
shift_create: event_id 8201, worker_id 701, start 2026-09-08T08:40:00-07:00, end 2026-09-08T09:00:00-07:00,
              idempotency_key "shift-job-4"   → 99104

sqlite_execute: UPDATE jobs SET zensched_event_id = 8201, zensched_shift_id = 99102 WHERE job_id = 2;
sqlite_execute: UPDATE jobs SET zensched_event_id = 8201, zensched_shift_id = 99103 WHERE job_id = 3;
sqlite_execute: UPDATE jobs SET zensched_event_id = 8201, zensched_shift_id = 99104 WHERE job_id = 4;
```

All three shifts hang off the **same** lot event. Re-running "schedule the week" returns no `fleet_due_this_week` rows.

> Scheduled 3 fleet washes Tuesday at Cascade Kent: Van 1 8:00, Van 2 8:20, Van 3 8:40, $25 each. Same lot pin, no new geocode. Each van is about $0.35 once you punch and I read the photo report.

## Tuesday: the fleet, then Saturday the driveway

Tuesday 7:55, at the Kent lot: Jordan checks in on Van 1 (GPS: 41 m from the pin, verified, $0.10). Washes. Job Report: Package = Fleet wash; After photos = 2; Add-ons empty; Upsell = 0. Check out 8:18. Repeats for Van 2 and Van 3.

Saturday 10:04, Maple Ave: check-in 9 m verified. Full detail, pet hair, customer asks for wax. Job Report: Package = Full detail; Paint meter = 4.2; Before = 3 photos; After = 3 photos; Add-ons = Pet hair, Wax; Upsell amount = 25. Check out 12:18.

## "Close out today. Cascade was routine. Priya: pet hair is $40, she added the $25 wax."

The agent is running this Saturday evening, so "today" is Priya; Cascade was Tuesday — the owner also wants those closed. The agent takes the date range covering both.

```
shift_status: shift_id 99102
  → status "checked_out", actual_in "2026-09-08T07:55:10-07:00", actual_out "2026-09-08T08:18:40-07:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 41 }, { type: "out", gps_verified: true } ]
(same for 99103, 99104, 99101)
```

> Reading 4 Job Reports with photos costs about $0.60. It bills once; after this I answer from the local record. OK?

Owner: *"go"*

```
form_export:
  form_id: 501
  since: "2026-09-08"
  until: "2026-09-12"
  format: "json"
  → 4 submissions, billing { meter: "form_media", units: 4, price: 0.60 }

  J-2026-0002 (event 8201, ~08:18): { package: "fleet_wash" }
  J-2026-0003 (event 8201, ~08:39): { package: "fleet_wash" }
  J-2026-0004 (event 8201, ~08:59): { package: "fleet_wash" }
  J-2026-0001 (event 8101): { package: "full_detail", paint_meter: 4.2,
       addons: ["pet_hair", "wax"], upsell: 25,
       notes: "Heavy pet hair on second row." }
```

Fleet submissions share event 8201; the agent matches them to shifts by `submitted_at` time.

```
sqlite_execute:
  UPDATE jobs SET status = 'completed', form_package = 'fleet_wash', report_dc_id = 3502,
      checked_in_at = '2026-09-08T07:55:10-07:00', checked_out_at = '2026-09-08T08:18:40-07:00',
      gps_verified = 1, checkin_distance_m = 41
  WHERE job_id = 2;
(same pattern for jobs 3 and 4)

sqlite_execute:
  UPDATE jobs
  SET status = 'completed', form_package = 'full_detail', paint_meter = 4.2,
      addons = '["pet_hair","wax"]', addon_amount = 40, upsell_amount = 25,
      report_dc_id = 3501, notes = 'Heavy pet hair on second row.',
      checked_in_at = '2026-09-12T10:04:00-07:00', checked_out_at = '2026-09-12T12:18:20-07:00',
      gps_verified = 1, checkin_distance_m = 9
  WHERE job_id = 1;
```

> Closed 4 jobs. Cascade Kent: three fleet washes, GPS on the lot, $75 receivable net 30. **J-2026-0001** Priya: full detail, paint meter 4.2 mils, after photos on file, $40 pet hair + $25 wax. $240 receivable net 14. GPS 10:04–12:18, 9 m from the pin.

## "Invoice Priya and Cascade."

```
sqlite_query: SELECT * FROM receivables_by_customer;
  → Priya Shah        | retail | net 14 | 1 job | 240.00 | 2026-09-12
    Cascade Plumbing  | fleet  | net 30 | 3 jobs | 75.00 | 2026-09-08

sqlite_execute:
  INSERT INTO invoices (customer_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.customer_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM customers WHERE customer_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('job_no', b.job_no, 'date', b.job_date, 'status', b.status,
                                      'package', b.package_amount, 'addon', b.addon_amount, 'upsell', b.upsell_amount,
                                      'billable', b.billable_total, 'shift_id', b.zensched_shift_id))
  FROM billable_jobs b WHERE b.invoiced = 0 AND b.customer_id = 1 AND b.billable_total > 0 GROUP BY b.customer_id;
sqlite_execute: UPDATE jobs SET invoiced = 1 WHERE invoiced = 0 AND customer_id = 1 AND status IN ('completed', 'no_show', 'cancelled');
  → INV-2026-0001 | $240.00 | due +14

(same three statements for customer 2 → INV-2026-0002 | $75.00 | due +30)
```

> Here's Priya's invoice:
>
> ```
> Harbor Shine Mobile Detail
> Invoice INV-2026-0001
> To: Priya Shah
> Date: Sep 12, 2026    Due: Sep 26, 2026 (net 14)
>
>   J-2026-0001  Sat Sep 12  2019 CR-V  Full detail $175.00 + pet hair $40.00 + wax $25.00    $240.00
>                            GPS-verified on site 10:04–12:18
>
> Total due: $240.00
> ```
>
> Cascade Plumbing INV-2026-0002, $75 (Van 1 / Van 2 / Van 3 fleet wash $25 each, Tue Sep 8), due Oct 12. No plates or VINs on either. Say "sent" when they're emailed.

## "Add Luis Mora, luis@harborshine.example, I pay him $80 a job. Give him next Tuesday's Cascade vans."

```
worker_invite:
  email: "luis@harborshine.example"
  first_name: "Luis"
  last_name: "Mora"
  idempotency_key: "worker-luis@harborshine.example"
  → worker_id: 702, billing: { meter: "worker_invite", price: 0.25 }

sqlite_execute:
  INSERT INTO detailers (detailer_name, email, zensched_worker_id, is_owner, payout_type, payout_value)
  VALUES ('Luis Mora', 'luis@harborshine.example', 702, 0, 'flat', 80);
  → lastInsertRowid = 2
```

Next Tuesday the agent inserts three jobs from `fleet_due_this_week` (the previous Tuesday's rows are already jobs, so they drop off), then `shift_create` for worker 702. When those jobs close, `INSERT INTO payouts (detailer_id, job_id)` × 3; the trigger sets `amount = 80`. `payouts_due` shows Luis $240.

> Luis is invited. Next Tuesday's three Cascade vans will land on his phone. You pay him $80 a van — $240 that week — and I'll list it when you ask "what do I owe Luis." Gate code you pass to him yourself.

## "Mileage—wait, the CR-V no-showed instead. Rewrite Saturday."

(Alternate ending the owner might hit on a different week.) Jordan checks in at 10:02 (GPS 11 m), nobody home, waits, Job Report still submitted with after photos of the empty driveway so the form can complete, notes "No access, called twice."

```
sqlite_execute:
  UPDATE jobs
  SET status = 'no_show', report_dc_id = 3509,
      checked_in_at = '2026-09-12T10:02:00-07:00', checked_out_at = '2026-09-12T10:41:00-07:00',
      gps_verified = 1, checkin_distance_m = 11,
      notes = 'No access, called twice.'
  WHERE job_id = 1;

sqlite_query: SELECT * FROM no_show_evidence WHERE job_id = 1;
  → J-2026-0001 | Priya Shah | 2019 CR-V | 2026-09-12T10:00 | 4412 Maple Ave, University Place, WA 98466
    | shift 99101 | in 10:02 | out 10:41 | gps 1 | 11 m | 39 min on site | trip_fee 25 | billable_total 25
```

`package_amount` 175 is still on the row; `billable_jobs` bills only the $25 trip.

> J-2026-0001 recorded as a no-show. Billable: $25 trip fee. GPS-verified on site 10:02–10:41 (11 m). I can put that on her invoice as "Trip fee — no access; GPS-verified arrival 10:02."

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Plates, VINs, gate codes | SQLite **only** (`vehicles.plate`, `vehicles.vin`, `sites.access_notes`) | Never reach ZenSched |
| Priya, Cascade: terms, trip fee, billing email | SQLite (`customers`) | Billing |
| Each driveway / lot, normalized, with its location id and `event_mode` | SQLite (`sites`) | De-dup cache; rolling vs one-off |
| `Shah - Maple Ave`, `Cascade Plumbing - Kent` and their GPS pins | ZenSched (ID in `sites`) | Geofenced check-in; labels carry no plate |
| One single-day event per on-demand job (`Full detail J-2026-0001`) | ZenSched (ID in `jobs`) | Title is package + number only |
| One rolling ≤60-day event per fleet lot (`Detailing - Cascade Plumbing - Kent`) | ZenSched (ID in `sites`) | All vans that week share it |
| One shift per job | ZenSched (ID in `jobs`) | Live schedule; never copied |
| Jordan as owner-worker; Luis as contractor | ZenSched (ID in `detailers`) | App login |
| GPS punches | ZenSched (originals); stamps copied once onto `jobs` | Proof of arrival, free afterwards |
| The Job Report form | ZenSched (ID in `settings`) | No signature field; after photos required |
| Four Job Report submissions | ZenSched (originals); package / meter / add-ons / upsell / photo URL JSON / `report_dc_id` on `jobs` | Read once (metered), then answered from SQLite |
| Check-in policy (200 m, 15 min early, 15 min check-out reminder) | ZenSched (policy 0) | Radius is enforced by the policy, not per site |
| Fees, two invoices, aging | SQLite (`jobs`, `billable_jobs`, `invoices`, `invoices_outstanding`) | Receivables |
| Luis's $80-flat payouts | SQLite (`payouts`) | Contractor mode only |
