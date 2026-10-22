-- Times are ISO-8601 UTC text in the same format as JS Date#toISOString().

-- One row per backant Google account email. The trial starts when the row is
-- created (first shepetal sign-in, web or device). 'expired' is never stored:
-- it is a 'trial' row older than 30 days. 'active' never expires.
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE,
  trial_started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  status TEXT NOT NULL DEFAULT 'trial' CHECK (status IN ('trial', 'active')),
  purchased_at TEXT
);

-- App access tokens. Only the SHA-256 hex of the token is stored.
CREATE TABLE tokens (
  hash TEXT PRIMARY KEY,
  email TEXT NOT NULL REFERENCES users (email),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  revoked_at TEXT
);

-- Device login. Only the SHA-256 hex of device_code is stored.
-- status: pending -> approved (email set by /device) or denied;
--         approved -> consumed when /api/device/token mints the access token.
CREATE TABLE device_codes (
  device_code_hash TEXT PRIMARY KEY,
  user_code TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied', 'consumed')),
  email TEXT,
  expires_at TEXT NOT NULL,
  last_polled_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
