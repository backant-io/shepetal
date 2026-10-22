-- The waitlist for the platforms shepetal is not on yet (/waitlist, src/lib/waitlist.ts). Double opt-in: a row counts
-- only once confirmed_at is set and unsubscribed_at is not. Times are ISO-8601 (UTC), written by the Worker.
-- A row that is not a confirmed, subscribed entry is deleted 30 days after its last signup (the daily sweep in
-- worker.ts). After a platform comes out, it is taken off every row 30 days later, and a row left with none is deleted.
CREATE TABLE waitlist (
  -- lowercased
  email TEXT PRIMARY KEY,
  -- comma-separated, sorted: any of iphone, linux, windows
  platforms TEXT NOT NULL,
  created_at TEXT NOT NULL,
  confirmed_at TEXT,
  unsubscribed_at TEXT,
  -- the checkbox's words, as the form showed them when the signup came in
  consent_text TEXT NOT NULL,
  -- HMAC-SHA256 of the IP address under AUTH_SECRET, for the throttle and abuse only
  ip_hash TEXT NOT NULL,
  -- the last signup for this email (the throttle and the sweep)
  last_request_at TEXT NOT NULL,
  -- the last confirmation email sent, or logged while WAITLIST_EMAILS is off (one per email per 30 minutes)
  last_mail_at TEXT
);

-- The per-IP throttle counts recent signups by ip_hash.
CREATE INDEX waitlist_ip ON waitlist (ip_hash, last_request_at);
