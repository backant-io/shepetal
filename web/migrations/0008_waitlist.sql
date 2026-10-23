-- The waitlist for the platforms shepetal is not on yet (/waitlist, src/lib/waitlist.ts), used only to tell each
-- person once shepetal is out on a platform they chose. Double opt-in: a row counts only once confirmed_at is set.
-- Times are ISO-8601 (UTC), written by the Worker. An unsubscribe deletes the row. A row that is not confirmed is
-- deleted 29 days after its last signup (the daily sweep in worker.ts). After a platform comes out and its email has
-- gone, it is taken off every row, and a row left with none is deleted.
-- 0005 and 0006 are taken by other branches. It creates only the table waitlist and its indexes, so it applies after
-- 0001 to 0004, 0006 and 0007 in any order.
CREATE TABLE waitlist (
  -- random, 16 bytes base64url: what the signed links carry, so no URL ever holds the address
  id TEXT NOT NULL UNIQUE,
  -- lowercased
  email TEXT PRIMARY KEY,
  -- comma-separated, sorted: any of iphone, linux, windows
  platforms TEXT NOT NULL,
  created_at TEXT NOT NULL,
  confirmed_at TEXT,
  -- the checkbox's words, as the form showed them when the signup came in (the proof of consent, with confirmed_at)
  consent_text TEXT NOT NULL,
  -- HMAC-SHA256 of the IP address under AUTH_SECRET, for the throttle only
  ip_hash TEXT NOT NULL,
  -- the last signup for this email (the throttle and the sweep)
  last_request_at TEXT NOT NULL,
  -- the last confirmation email sent (one per email per 30 minutes, and the hourly cap on all of them)
  last_mail_at TEXT
);

-- The per-IP throttle counts recent signups by ip_hash.
CREATE INDEX waitlist_ip ON waitlist (ip_hash, last_request_at);
-- The hourly cap counts recent confirmation emails.
CREATE INDEX waitlist_mail ON waitlist (last_mail_at);
