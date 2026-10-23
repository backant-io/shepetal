-- The trial emails (src/lib/lifecycle.ts): welcome, a tip on day 3, and on day 25 the note that the trial ends in 5
-- days. 0004 and 0005 are taken by other branches. Applied after 0007 in production (0007 went out first): it touches
-- nothing 0007 made.

-- When the user ticked "Send me three short emails about my trial." (src/lib/trial-emails.ts), the consent the emails
-- need. NULL: never ticked, and no trial email goes out. Users from before this column get nothing unless they tick it.
ALTER TABLE users ADD COLUMN trial_emails_at TEXT;

-- One row per user and email, claimed before it is sent, so no email goes out twice, even when two cron runs overlap.
-- status: sending (claimed; a row left here by a run that was cut off is never sent again: it may have gone out),
--         sent (SES took it; message_id is SES's id), failed (SES refused this one message: MessageRejected or a bad
--         recipient address; not retried).
-- On any other SES error (429, 5xx, a paused or suspended account, a wrong region, no answer) the row is deleted
-- again and the run stops, and a later run tries while the email's window is open.
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
