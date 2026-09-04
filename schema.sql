-- ZenSched Mobile-Detailing Local Database Schema
-- SQLite database for customers (retail + fleet), vehicles, work sites,
-- one-off on-demand jobs, recurring fleet schedules, Job Report summaries,
-- invoices / receivables, and contractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my detail-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 detail-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- TWO SCHEDULE SHAPES. On-demand retail jobs (a driveway full detail this
-- Saturday) work like a one-off appointment: one job row, one single-day
-- ZenSched event, one shift. Recurring fleet work (wash Cascade's vans every
-- Tuesday at the Kent lot) works like a pet-care route: a weekday-mask
-- template on job_schedule, one permanent location per site, a rolling
-- <=60-day event, and one job + shift per vehicle per due date.
--
-- PRIVACY: vehicle plates, VINs, gate / garage codes, and parking notes live
-- ONLY in this file on your computer: vehicles.plate, vehicles.vin,
-- sites.access_notes, sites.parking_notes; retail customers' names stay in
-- customers. ZenSched receives a site label ("Maple Ave - University Place"
-- for a driveway, "Cascade Plumbing - Kent" for a business lot), the street address for the
-- GPS pin, an event title made of the package and job number (or
-- "Detailing - <site_label>" for a fleet lot), and the Job Report the
-- detailer fills in on the phone. SKILL.md forbids the agent from putting
-- any local-only column into a ZenSched field.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Mobile Detail');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '-05:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_detailer_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_job_minutes', '90');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_travel_buffer_minutes', '20');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '14');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('job_report_form_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('event_window_days', '60');

-- Packages: your price list. Seeded with common mobile-detail items; edit
-- prices freely. jobs.package_id is what was actually sold (a fleet-wash
-- account can still get a one-off interior).
CREATE TABLE IF NOT EXISTS packages (
  package_id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,                        -- short handle: 'full'
  package_name TEXT NOT NULL,                       -- shown on invoices
  default_minutes INTEGER NOT NULL,                 -- shift length on ZenSched
  price REAL NOT NULL,                              -- default dollars
  is_active INTEGER DEFAULT 1,
  notes TEXT
);

INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('ext_wash', 'Exterior wash', 45, 50.00);
INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('interior', 'Interior detail', 60, 75.00);
INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('full', 'Full detail', 150, 175.00);
INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('ceramic', 'Ceramic coat', 240, 450.00);
INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('paint_corr', 'Paint correction', 300, 550.00);
INSERT OR IGNORE INTO packages (code, package_name, default_minutes, price) VALUES ('fleet_wash', 'Fleet wash', 20, 25.00);

-- Customers: who pays. Retail (one car in a driveway) and fleet / dealership
-- / rental accounts (a lot of vehicles at a site). payment_terms_days drives
-- invoice due dates; default_trip_fee is what a no-show bills.
CREATE TABLE IF NOT EXISTS customers (
  customer_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_name TEXT NOT NULL,
  customer_type TEXT NOT NULL DEFAULT 'retail'
    CHECK (customer_type IN ('retail', 'fleet', 'dealership', 'rental', 'other')),
  contact_name TEXT,
  contact_phone TEXT,
  contact_email TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 14,   -- net 14 retail; fleet often 30
  default_trip_fee REAL,                            -- $ owed when they no-show after you travelled
  billing_notes TEXT,                               -- 'pays by Venmo', 'invoice monthly', ...
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Sites: where you work — a driveway, a fleet lot, a dealership, your shop.
-- normalized_address is unique per customer (the agent builds it as
-- lowercase(address + city + state + zip) with commas, periods, and '#'
-- removed and whitespace collapsed). Look here FIRST and only call
-- location_create (geocode, $0.03) on a miss.
--
-- event_mode:
--   one_off  — retail / on-demand: one single-day ZenSched event per job
--              (event-job-{job_id}). zensched_event_id on the site is unused.
--   rolling  — fleet lots: one <=60-day event per site, rolled when a job
--              date is past event_valid_until. Never create an event per car.
CREATE TABLE IF NOT EXISTS sites (
  site_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  site_label TEXT,                                  -- sent to ZenSched: 'Maple Ave - University Place' (driveway), 'Acme Fleet - Kent' (lot); never a homeowner's name
  site_kind TEXT NOT NULL DEFAULT 'driveway'
    CHECK (site_kind IN ('driveway', 'lot', 'shop', 'dealership', 'other')),
  event_mode TEXT NOT NULL DEFAULT 'one_off'
    CHECK (event_mode IN ('one_off', 'rolling')),
  normalized_address TEXT NOT NULL,
  address TEXT NOT NULL,
  city TEXT,
  state TEXT,
  zip TEXT,
  access_notes TEXT,                                -- LOCAL ONLY: gate code, garage opener, 'park on street'
  parking_notes TEXT,                               -- LOCAL ONLY
  zensched_location_id INTEGER,                     -- from location_create (permanent)
  zensched_event_id INTEGER,                        -- current rolling window (fleet only)
  event_valid_until TEXT,                           -- ISO date: last day the current rolling event covers
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE
);

-- Vehicles: the cars, vans, trucks you actually work on. plate and vin are
-- LOCAL ONLY and never reach ZenSched. vehicle_label is the human shorthand
-- the owner uses ("2019 CR-V", "Van 3") — used in local summaries, not in
-- ZenSched titles. site_id pins a fleet vehicle to its lot.
CREATE TABLE IF NOT EXISTS vehicles (
  vehicle_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  site_id INTEGER,                                  -- NULL = no home lot (retail one-off at any site)
  year INTEGER,
  make TEXT,
  model TEXT,
  color TEXT,
  plate TEXT,                                       -- LOCAL ONLY
  vin TEXT,                                         -- LOCAL ONLY
  vehicle_label TEXT,                               -- '2019 CR-V', 'Van 3'
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE,
  FOREIGN KEY (site_id) REFERENCES sites(site_id) ON DELETE SET NULL
);

-- Detailers: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. Add a row per contractor
-- with payout_type/payout_value ('flat' = $ per job, 'percent' = % of billable).
CREATE TABLE IF NOT EXISTS detailers (
  detailer_id INTEGER PRIMARY KEY AUTOINCREMENT,
  detailer_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('flat', 'percent')),
  payout_value REAL,                                -- $ (flat) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Job schedule: the recurring fleet template ("Cascade vans: Tue 08:00, fleet wash").
-- weekdays is a 7-character mask, Monday first: '0100000' = Tuesday.
-- One row per vehicle. The agent expands this into job rows + ZenSched shifts
-- once a week using the fleet_due_this_week view. Retail / on-demand jobs
-- do not use this table.
CREATE TABLE IF NOT EXISTS job_schedule (
  schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  site_id INTEGER NOT NULL,
  vehicle_id INTEGER NOT NULL,
  package_id INTEGER NOT NULL,
  weekdays TEXT NOT NULL
    CHECK (length(weekdays) = 7 AND weekdays NOT GLOB '*[^01]*'),
  preferred_start TEXT NOT NULL                     -- 'HH:MM' 24-hour local time
    CHECK (preferred_start GLOB '[0-2][0-9]:[0-5][0-9]'),
  zensched_worker_id INTEGER,                       -- NULL = settings.default_detailer_id's worker
  start_date TEXT,                                  -- first date this applies (NULL = already running)
  end_date TEXT,                                    -- last date (NULL = open-ended)
  is_active INTEGER DEFAULT 1,
  notes TEXT,                                       -- 'skip if pouring', 'keys in shop office'
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE,
  FOREIGN KEY (site_id) REFERENCES sites(site_id) ON DELETE CASCADE,
  FOREIGN KEY (vehicle_id) REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
  FOREIGN KEY (package_id) REFERENCES packages(package_id)
);

-- Jobs: THE driving table. One row per detailing job, on-demand or recurring.
-- On-demand: insert first, then a single-day event + shift.
-- Recurring: insert from fleet_due_this_week, then a shift on the site's
-- rolling event.
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- Amounts are per-job snapshots. Leave them NULL on insert and the
-- fill_job_defaults trigger copies the package price and the customer's
-- trip fee (else 0). Which amounts are billable depends on status; see
-- the billable_jobs view.
--
-- plate / vin / access notes never live here — they stay on vehicles / sites.
-- package (form key), paint_meter, addons, upsell_amount, photo URLs, and
-- report_dc_id come from the Job Report. GPS stamps are copied from
-- shift_status once so "was I on time" is free next time.
CREATE TABLE IF NOT EXISTS jobs (
  job_id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_no TEXT UNIQUE,                               -- 'J-2026-0001', filled by trigger if NULL
  customer_id INTEGER NOT NULL,
  vehicle_id INTEGER,
  site_id INTEGER NOT NULL,
  package_id INTEGER,                               -- NULL -> left unset; trigger does not invent a package
  schedule_id INTEGER,                              -- NULL for on-demand
  source TEXT NOT NULL DEFAULT 'on_demand'
    CHECK (source IN ('on_demand', 'recurring')),
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> package default or settings
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  detailer_id INTEGER,                              -- NULL -> settings.default_detailer_id
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('requested', 'confirmed', 'completed', 'no_show', 'cancelled', 'rescheduled')),
  package_amount REAL,                              -- NULL -> packages.price (trigger)
  addon_amount REAL,                                -- extras priced by the owner; form addons are keys
  upsell_amount REAL,                               -- from the Job Report currency field
  trip_fee REAL,                                    -- NULL -> customer.default_trip_fee, else 0
  other_fee REAL,                                   -- late-cancel, extra, ...
  zensched_event_id INTEGER,
  zensched_shift_id INTEGER UNIQUE,
  report_dc_id INTEGER,                             -- Job Report submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  form_package TEXT,                                -- form option key: full_detail, fleet_wash, ...
  paint_meter REAL,                                 -- mils, optional
  addons TEXT,                                      -- JSON array of option keys
  photo_before_urls TEXT,                           -- JSON array
  photo_after_urls TEXT,                            -- JSON array
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,
  rescheduled_from INTEGER,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE,
  FOREIGN KEY (vehicle_id) REFERENCES vehicles(vehicle_id) ON DELETE SET NULL,
  FOREIGN KEY (site_id) REFERENCES sites(site_id) ON DELETE RESTRICT,
  FOREIGN KEY (package_id) REFERENCES packages(package_id),
  FOREIGN KEY (schedule_id) REFERENCES job_schedule(schedule_id) ON DELETE SET NULL,
  FOREIGN KEY (detailer_id) REFERENCES detailers(detailer_id) ON DELETE SET NULL,
  FOREIGN KEY (rescheduled_from) REFERENCES jobs(job_id) ON DELETE SET NULL
);

-- Invoices: one per customer per billing run. invoice_number is filled by
-- trigger if left NULL. due_date is invoice_date + the customer's
-- payment_terms_days. line_items is a JSON array with one object per job.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (customer_id) REFERENCES customers(customer_id) ON DELETE CASCADE
);

-- Payouts: what you owe a contractor for one job. One row per job. amount
-- is filled by trigger when left NULL: flat -> payout_value; percent ->
-- billable_total * payout_value / 100. Never insert a payout for the owner.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  detailer_id INTEGER NOT NULL,
  job_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (detailer_id) REFERENCES detailers(detailer_id) ON DELETE CASCADE,
  FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE UNIQUE INDEX IF NOT EXISTS idx_sites_customer_norm ON sites(customer_id, normalized_address);
CREATE INDEX IF NOT EXISTS idx_sites_location ON sites(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_sites_event ON sites(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_customer ON vehicles(customer_id, is_active);
CREATE INDEX IF NOT EXISTS idx_vehicles_site ON vehicles(site_id);
CREATE INDEX IF NOT EXISTS idx_schedule_site ON job_schedule(site_id, is_active);
CREATE INDEX IF NOT EXISTS idx_schedule_vehicle ON job_schedule(vehicle_id, is_active);
CREATE INDEX IF NOT EXISTS idx_jobs_start ON jobs(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_jobs_status_start ON jobs(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_jobs_customer ON jobs(customer_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_jobs_site ON jobs(site_id);
CREATE INDEX IF NOT EXISTS idx_jobs_vehicle ON jobs(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_jobs_event ON jobs(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_jobs_schedule_date ON jobs(schedule_id, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_invoices_customer ON invoices(customer_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_detailer ON payouts(detailer_id, paid);
CREATE INDEX IF NOT EXISTS idx_detailers_worker ON detailers(zensched_worker_id);

-- Which amounts are billable depends on what happened. This is the single
-- place that rule lives; receivables, invoicing, and payouts all read
-- billable_total from here rather than re-deriving it.
--   completed  -> package + addon + upsell + other   (trip is not extra)
--   no_show    -> trip_fee                           (you travelled; nothing was detailed)
--   cancelled  -> other_fee only                     (late-cancel the agent puts in other_fee)
--   requested / confirmed / rescheduled -> 0
CREATE VIEW IF NOT EXISTS billable_jobs AS
SELECT
  j.job_id,
  j.job_no,
  j.customer_id,
  j.vehicle_id,
  j.site_id,
  j.package_id,
  j.source,
  j.status,
  date(j.scheduled_start)                          AS job_date,
  j.scheduled_start,
  j.detailer_id,
  j.package_amount,
  j.addon_amount,
  j.upsell_amount,
  j.trip_fee,
  j.other_fee,
  CASE j.status
    WHEN 'completed' THEN round(COALESCE(j.package_amount, 0) + COALESCE(j.addon_amount, 0) + COALESCE(j.upsell_amount, 0) + COALESCE(j.other_fee, 0), 2)
    WHEN 'no_show'   THEN round(COALESCE(j.trip_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(j.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  j.invoiced,
  j.paid_out,
  j.zensched_shift_id,
  j.report_dc_id
FROM jobs j;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_customer_timestamp
AFTER UPDATE ON customers
BEGIN
  UPDATE customers SET updated_at = datetime('now') WHERE customer_id = NEW.customer_id;
END;

CREATE TRIGGER IF NOT EXISTS update_site_timestamp
AFTER UPDATE ON sites
BEGIN
  UPDATE sites SET updated_at = datetime('now') WHERE site_id = NEW.site_id;
END;

CREATE TRIGGER IF NOT EXISTS update_vehicle_timestamp
AFTER UPDATE ON vehicles
BEGIN
  UPDATE vehicles SET updated_at = datetime('now') WHERE vehicle_id = NEW.vehicle_id;
END;

CREATE TRIGGER IF NOT EXISTS update_detailer_timestamp
AFTER UPDATE ON detailers
BEGIN
  UPDATE detailers SET updated_at = datetime('now') WHERE detailer_id = NEW.detailer_id;
END;

CREATE TRIGGER IF NOT EXISTS update_schedule_timestamp
AFTER UPDATE ON job_schedule
BEGIN
  UPDATE job_schedule SET updated_at = datetime('now') WHERE schedule_id = NEW.schedule_id;
END;

CREATE TRIGGER IF NOT EXISTS update_job_timestamp
AFTER UPDATE OF customer_id, vehicle_id, site_id, package_id, schedule_id, source, scheduled_start,
                duration_minutes, detailer_id, status, package_amount, addon_amount, upsell_amount,
                trip_fee, other_fee, zensched_event_id, zensched_shift_id, report_dc_id,
                checked_in_at, checked_out_at, gps_verified, checkin_distance_m, form_package,
                paint_meter, addons, photo_before_urls, photo_after_urls, notes, invoiced,
                paid_out, rescheduled_from
ON jobs
BEGIN
  UPDATE jobs SET updated_at = datetime('now') WHERE job_id = NEW.job_id;
END;

-- Auto-number jobs: J-2026-0001, J-2026-0002, ... (year of the job,
-- sequence = job_id, so numbers never collide or reset).
CREATE TRIGGER IF NOT EXISTS number_job
AFTER INSERT ON jobs
WHEN NEW.job_no IS NULL
BEGIN
  UPDATE jobs
  SET job_no = 'J-' || strftime('%Y', NEW.scheduled_start) || '-' || printf('%04d', NEW.job_id)
  WHERE job_id = NEW.job_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- package.default_minutes, else settings.default_job_minutes, else 90
--   detailer_id      <- settings.default_detailer_id
--   package_amount   <- packages.price, else 0
--   addon / upsell   <- 0
--   trip_fee         <- customers.default_trip_fee, else 0
--   other_fee        <- 0
--   source           <- recurring if schedule_id set, else the inserted value
-- Amounts are snapshots: changing a package price later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_job_defaults
AFTER INSERT ON jobs
BEGIN
  UPDATE jobs
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT default_minutes FROM packages WHERE package_id = NEW.package_id),
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_job_minutes'),
                                  90),
      detailer_id = COALESCE(NEW.detailer_id,
                             (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_detailer_id' AND value IS NOT NULL)),
      package_amount = COALESCE(NEW.package_amount, (SELECT price FROM packages WHERE package_id = NEW.package_id), 0),
      addon_amount   = COALESCE(NEW.addon_amount, 0),
      upsell_amount  = COALESCE(NEW.upsell_amount, 0),
      trip_fee       = COALESCE(NEW.trip_fee, (SELECT default_trip_fee FROM customers WHERE customer_id = NEW.customer_id), 0),
      other_fee      = COALESCE(NEW.other_fee, 0),
      source         = CASE WHEN NEW.schedule_id IS NOT NULL THEN 'recurring' ELSE COALESCE(NEW.source, 'on_demand') END
  WHERE job_id = NEW.job_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the detailer's split when the agent leaves it NULL.
-- flat    -> payout_value
-- percent -> billable_total * payout_value / 100, rounded to cents
-- If the detailer has no payout_type the amount stays NULL and payouts_due flags it.
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE d.payout_type
                         WHEN 'flat'    THEN d.payout_value
                         WHEN 'percent' THEN round(b.billable_total * d.payout_value / 100.0, 2)
                       END
                FROM detailers d
                JOIN billable_jobs b ON b.job_id = NEW.job_id
                WHERE d.detailer_id = NEW.detailer_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Today's open jobs (local date of the computer running the database).
-- start_iso / end_iso carry settings.timezone_offset and are ready for
-- shift_create. The three idempotency keys and the ZenSched names are ready too.
--   needs_location = 1 -> the site has no ZenSched location yet
--   needs_shift    = 1 -> the job has no ZenSched shift yet
--   event_needs_roll = 1 -> rolling site, current event missing or expired for this date
CREATE VIEW IF NOT EXISTS jobs_today AS
SELECT
  j.job_id,
  j.job_no,
  j.status,
  j.source,
  j.scheduled_start,
  j.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', j.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(j.scheduled_start, '+' || j.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.customer_id,
  c.customer_name,
  c.customer_type,
  v.vehicle_id,
  v.vehicle_label,
  v.year,
  v.make,
  v.model,
  v.color,
  v.plate,
  s.site_id,
  s.site_label,
  s.site_kind,
  s.event_mode,
  s.address,
  s.city,
  s.state,
  s.zip,
  s.address || COALESCE(', ' || s.city, '') || COALESCE(', ' || s.state, '') || COALESCE(' ' || s.zip, '') AS street_address,
  COALESCE(s.site_label, 'Detailing ' || j.job_no)                                AS zensched_location_name,
  CASE s.event_mode
    WHEN 'rolling' THEN 'Detailing - ' || COALESCE(s.site_label, 'site ' || s.site_id)
    ELSE COALESCE(pkg.package_name, 'Detail') || ' ' || j.job_no
  END                                                                            AS zensched_event_title,
  s.access_notes,
  s.parking_notes,
  s.zensched_location_id,
  CASE WHEN s.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  s.zensched_event_id,
  s.event_valid_until,
  CASE
    WHEN s.event_mode = 'rolling'
     AND (s.zensched_event_id IS NULL OR s.event_valid_until IS NULL OR s.event_valid_until < date(j.scheduled_start))
    THEN 1 ELSE 0
  END                                                                            AS event_needs_roll,
  j.zensched_event_id                                                            AS job_event_id,
  j.zensched_shift_id,
  CASE WHEN j.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  j.detailer_id,
  d.detailer_name,
  d.zensched_worker_id,
  j.package_id,
  pkg.code                                                                       AS package_code,
  pkg.package_name,
  j.package_amount,
  j.notes,
  'loc-site-' || s.site_id                                                        AS loc_idempotency_key,
  CASE s.event_mode
    WHEN 'rolling' THEN 'event-site-' || s.site_id || '-' || strftime('%Y%m%d', j.scheduled_start)
    ELSE 'event-job-' || j.job_id
  END                                                                            AS event_idempotency_key,
  'shift-job-' || j.job_id                                                        AS shift_idempotency_key
FROM jobs j
JOIN customers c ON c.customer_id = j.customer_id
JOIN sites s ON s.site_id = j.site_id
LEFT JOIN vehicles v ON v.vehicle_id = j.vehicle_id
LEFT JOIN packages pkg ON pkg.package_id = j.package_id
LEFT JOIN detailers d ON d.detailer_id = j.detailer_id
WHERE j.status IN ('requested', 'confirmed')
  AND date(j.scheduled_start) = date('now', 'localtime')
ORDER BY j.scheduled_start;

-- Same columns, next 7 days (today through today + 6).
CREATE VIEW IF NOT EXISTS jobs_upcoming AS
SELECT
  j.job_id,
  j.job_no,
  j.status,
  j.source,
  j.scheduled_start,
  j.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', j.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(j.scheduled_start, '+' || j.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.customer_id,
  c.customer_name,
  c.customer_type,
  v.vehicle_id,
  v.vehicle_label,
  v.year,
  v.make,
  v.model,
  v.color,
  v.plate,
  s.site_id,
  s.site_label,
  s.site_kind,
  s.event_mode,
  s.address,
  s.city,
  s.state,
  s.zip,
  s.address || COALESCE(', ' || s.city, '') || COALESCE(', ' || s.state, '') || COALESCE(' ' || s.zip, '') AS street_address,
  COALESCE(s.site_label, 'Detailing ' || j.job_no)                                AS zensched_location_name,
  CASE s.event_mode
    WHEN 'rolling' THEN 'Detailing - ' || COALESCE(s.site_label, 'site ' || s.site_id)
    ELSE COALESCE(pkg.package_name, 'Detail') || ' ' || j.job_no
  END                                                                            AS zensched_event_title,
  s.access_notes,
  s.parking_notes,
  s.zensched_location_id,
  CASE WHEN s.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  s.zensched_event_id,
  s.event_valid_until,
  CASE
    WHEN s.event_mode = 'rolling'
     AND (s.zensched_event_id IS NULL OR s.event_valid_until IS NULL OR s.event_valid_until < date(j.scheduled_start))
    THEN 1 ELSE 0
  END                                                                            AS event_needs_roll,
  j.zensched_event_id                                                            AS job_event_id,
  j.zensched_shift_id,
  CASE WHEN j.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  j.detailer_id,
  d.detailer_name,
  d.zensched_worker_id,
  j.package_id,
  pkg.code                                                                       AS package_code,
  pkg.package_name,
  j.package_amount,
  j.notes,
  'loc-site-' || s.site_id                                                        AS loc_idempotency_key,
  CASE s.event_mode
    WHEN 'rolling' THEN 'event-site-' || s.site_id || '-' || strftime('%Y%m%d', j.scheduled_start)
    ELSE 'event-job-' || j.job_id
  END                                                                            AS event_idempotency_key,
  'shift-job-' || j.job_id                                                        AS shift_idempotency_key
FROM jobs j
JOIN customers c ON c.customer_id = j.customer_id
JOIN sites s ON s.site_id = j.site_id
LEFT JOIN vehicles v ON v.vehicle_id = j.vehicle_id
LEFT JOIN packages pkg ON pkg.package_id = j.package_id
LEFT JOIN detailers d ON d.detailer_id = j.detailer_id
WHERE j.status IN ('requested', 'confirmed')
  AND date(j.scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY j.scheduled_start;

-- Recurring fleet jobs that should happen in the next 7 days, expanded from
-- job_schedule, minus dates that already have a live job for that schedule
-- row. One row = one INSERT INTO jobs, then the usual ZenSched steps from
-- jobs_upcoming. weekdays is Monday-first; SQLite %w is Sunday=0.
CREATE VIEW IF NOT EXISTS fleet_due_this_week AS
WITH RECURSIVE days(d) AS (
  SELECT date('now', 'localtime')
  UNION ALL
  SELECT date(d, '+1 day') FROM days WHERE d < date('now', 'localtime', '+6 days')
)
SELECT
  days.d                                     AS visit_date,
  s.schedule_id,
  c.customer_id,
  c.customer_name,
  c.customer_type,
  si.site_id,
  si.site_label,
  si.site_kind,
  si.event_mode,
  si.address,
  si.city,
  si.state,
  si.zip,
  si.address || COALESCE(', ' || si.city, '') || COALESCE(', ' || si.state, '') || COALESCE(' ' || si.zip, '') AS street_address,
  si.access_notes,
  si.zensched_location_id,
  si.zensched_event_id,
  si.event_valid_until,
  CASE WHEN si.zensched_location_id IS NULL THEN 1 ELSE 0 END AS needs_location,
  CASE
    WHEN si.event_mode = 'rolling'
     AND (si.zensched_event_id IS NULL OR si.event_valid_until IS NULL OR si.event_valid_until < days.d)
    THEN 1 ELSE 0
  END                                        AS event_needs_roll,
  v.vehicle_id,
  v.vehicle_label,
  v.year,
  v.make,
  v.model,
  v.color,
  v.plate,
  pkg.package_id,
  pkg.code                                   AS package_code,
  pkg.package_name,
  pkg.default_minutes,
  pkg.price,
  s.preferred_start,
  COALESCE(s.zensched_worker_id,
           (SELECT d.zensched_worker_id FROM detailers d
             WHERE d.detailer_id = (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_detailer_id' AND value IS NOT NULL))) AS worker_id,
  days.d || 'T' || s.preferred_start || ':00' || (SELECT value FROM settings WHERE key = 'timezone_offset') AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(days.d || ' ' || s.preferred_start || ':00', '+' || pkg.default_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset') AS end_iso,
  s.notes                                    AS schedule_notes
FROM days
JOIN job_schedule s
  ON s.is_active = 1
 AND substr(s.weekdays, CASE strftime('%w', days.d) WHEN '0' THEN 7 ELSE CAST(strftime('%w', days.d) AS INTEGER) END, 1) = '1'
 AND (s.start_date IS NULL OR s.start_date <= days.d)
 AND (s.end_date IS NULL OR s.end_date >= days.d)
JOIN customers c ON c.customer_id = s.customer_id AND c.is_active = 1
JOIN sites si ON si.site_id = s.site_id AND si.is_active = 1
JOIN vehicles v ON v.vehicle_id = s.vehicle_id AND v.is_active = 1
JOIN packages pkg ON pkg.package_id = s.package_id
WHERE NOT EXISTS (
  SELECT 1 FROM jobs j
  WHERE j.schedule_id = s.schedule_id
    AND date(j.scheduled_start) = days.d
    AND j.status NOT IN ('cancelled', 'rescheduled')
)
ORDER BY days.d, s.preferred_start, c.customer_name, v.vehicle_label;

-- Rolling sites whose current ZenSched event expires within 14 days (or has
-- none) and that still have an active recurring schedule. Roll these proactively.
CREATE VIEW IF NOT EXISTS events_expiring AS
SELECT
  si.site_id,
  c.customer_name,
  si.site_label,
  si.address,
  si.zensched_location_id,
  si.zensched_event_id,
  si.event_valid_until
FROM sites si
JOIN customers c ON c.customer_id = si.customer_id AND c.is_active = 1
WHERE si.is_active = 1
  AND si.event_mode = 'rolling'
  AND EXISTS (SELECT 1 FROM job_schedule s WHERE s.site_id = si.site_id AND s.is_active = 1)
  AND (si.event_valid_until IS NULL OR si.event_valid_until <= date('now', 'localtime', '+14 days'))
ORDER BY si.event_valid_until;

-- Uninvoiced billable work grouped by customer, with the billing contact and
-- terms. Completed jobs bill package + addon + upsell + other; no-shows bill
-- trip_fee only; cancellations bill other_fee only (see billable_jobs).
CREATE VIEW IF NOT EXISTS receivables_by_customer AS
SELECT
  c.customer_id,
  c.customer_name,
  c.customer_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  COUNT(b.job_id)                                  AS job_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_show' THEN 1 ELSE 0 END)   AS no_show_count,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.job_date)                                  AS first_date,
  MAX(b.job_date)                                  AS last_date
FROM billable_jobs b
JOIN customers c ON c.customer_id = b.customer_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_show', 'cancelled')
  AND b.billable_total > 0
GROUP BY c.customer_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  i.invoice_id,
  i.invoice_number,
  c.customer_id,
  c.customer_name,
  c.customer_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  i.invoice_date,
  i.due_date,
  i.sent_date,
  i.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(i.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(i.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN i.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices i
JOIN customers c ON c.customer_id = i.customer_id
WHERE i.paid = 0
ORDER BY i.due_date;

-- Contractor mode: unpaid sub payouts, one row per job, with a running
-- total per detailer. Owner rows never appear.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  d.detailer_id,
  d.detailer_name,
  d.email,
  d.payout_type,
  d.payout_value,
  j.job_id,
  j.job_no,
  date(j.scheduled_start)                          AS job_date,
  j.status,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY d.detailer_id)  AS detailer_total_due,
  j.invoiced                                       AS customer_invoiced
FROM payouts p
JOIN detailers d ON d.detailer_id = p.detailer_id
JOIN jobs j ON j.job_id = p.job_id
JOIN billable_jobs b ON b.job_id = j.job_id
WHERE p.paid = 0
  AND d.is_owner = 0
ORDER BY d.detailer_name, j.scheduled_start;

-- Contractor mode: completed / no-show jobs worked by a sub that have no
-- payouts row yet.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  j.job_id,
  j.job_no,
  j.status,
  date(j.scheduled_start)                          AS job_date,
  d.detailer_id,
  d.detailer_name,
  d.payout_type,
  d.payout_value,
  b.billable_total
FROM jobs j
JOIN detailers d ON d.detailer_id = j.detailer_id AND d.is_owner = 0
JOIN billable_jobs b ON b.job_id = j.job_id
WHERE j.status IN ('completed', 'no_show')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.job_id = j.job_id)
ORDER BY j.scheduled_start;

-- What the agent cites when chasing a trip fee: every no-show with the
-- ZenSched shift (GPS-verified arrival) and the Job Report that documents
-- the wait, plus the fee that is owed.
CREATE VIEW IF NOT EXISTS no_show_evidence AS
SELECT
  j.job_id,
  j.job_no,
  c.customer_name,
  c.customer_type,
  c.billing_email,
  v.vehicle_label,
  j.scheduled_start,
  strftime('%Y-%m-%dT%H:%M:%S', j.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  s.address || COALESCE(', ' || s.city, '') || COALESCE(', ' || s.state, '') || COALESCE(' ' || s.zip, '') AS street_address,
  d.detailer_name,
  j.zensched_event_id,
  j.zensched_shift_id,
  j.report_dc_id,
  j.checked_in_at,
  j.checked_out_at,
  j.gps_verified,
  j.checkin_distance_m,
  CASE WHEN j.checked_in_at IS NOT NULL AND j.checked_out_at IS NOT NULL
       THEN CAST(round((julianday(j.checked_out_at) - julianday(j.checked_in_at)) * 1440.0) AS INTEGER) END AS minutes_on_site,
  j.trip_fee,
  b.billable_total,
  j.invoiced,
  j.notes
FROM jobs j
JOIN customers c ON c.customer_id = j.customer_id
JOIN sites s ON s.site_id = j.site_id
JOIN billable_jobs b ON b.job_id = j.job_id
LEFT JOIN vehicles v ON v.vehicle_id = j.vehicle_id
LEFT JOIN detailers d ON d.detailer_id = j.detailer_id
WHERE j.status = 'no_show'
ORDER BY j.scheduled_start DESC;
