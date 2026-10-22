-- The trial emails (src/lib/lifecycle.ts): welcome, a tip on day 3, and on day 25 the note that the trial ends in 5
-- days. 0004 and 0005 are taken by other branches.

-- One row per user and email, claimed before it is sent, so no email goes out twice, even when two cron runs overlap.
-- status: sending (claimed; a row left here by a run that was cut off is never sent again: it may have gone out),
--         sent (SES took it; message_id is SES's id), failed (SES refused it, or the answer never came: not retried).
-- When SES answers 429 or 5xx the row is deleted again, and the next run tries while the email's window is open.
CREATE TABLE lifecycle_emails (
  user_id INTEGER NOT NULL REFERENCES users (id),
  kind TEXT NOT NULL CHECK (kind IN ('welcome', 'day3', 'day25')),
  status TEXT NOT NULL DEFAULT 'sending' CHECK (status IN ('sending', 'sent', 'failed')),
  claimed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  sent_at TEXT,
  message_id TEXT,
  error TEXT,
  PRIMARY KEY (user_id, kind)
);

-- Users who unsubscribed from the trial emails (the signed link in every one of them, GET /unsubscribe then POST).
CREATE TABLE email_unsubscribes (
  user_id INTEGER PRIMARY KEY REFERENCES users (id),
  unsubscribed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Each cron run asks for the users whose trial started inside an email's window.
CREATE INDEX users_trial_started ON users (trial_started_at);
