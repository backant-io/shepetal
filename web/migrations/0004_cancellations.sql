-- Cancellations sent with the "Verträge hier kündigen" button (/cancel, § 312k BGB), kept as the record of what was
-- declared and when, with what was done about it. A row is deleted three years after the end of the year it came in
-- (the limitation period), by the next cancellation after that.
CREATE TABLE cancellations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at TEXT NOT NULL,
  email TEXT NOT NULL,
  -- 'ordinary' or 'extraordinary' (for good cause, with the reason)
  kind TEXT NOT NULL,
  reason TEXT,
  -- 'monthly' or 'lifetime', as the sender chose
  contract TEXT NOT NULL,
  -- the requested end (YYYY-MM-DD), NULL for as soon as possible
  end_requested TEXT,
  -- the account under that email, if there is one
  user_id INTEGER,
  -- what was done: cancelled_at_period_end, cancel_at, no_subscription, no_account, error
  outcome TEXT NOT NULL
);
