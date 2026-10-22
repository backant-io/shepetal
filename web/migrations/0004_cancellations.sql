-- Cancellations sent with the "Verträge hier kündigen" button (/cancel, § 312k BGB), kept as the record of what was
-- declared and when, with what was done about it. A row is deleted three years after the end of the year it came in
-- (the limitation period), by the next cancellation sent after that.
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
  -- what was done: cancelled, already_ending, no_subscription, lifetime, no_account, error
  outcome TEXT NOT NULL,
  -- when the subscription ends, as Stripe has it after the cancellation (ISO), if one was cancelled
  ends_at TEXT
);

-- When a cancelled subscription ends (Stripe's cancel_at, ISO): the end of the paid period, or a later date asked for
-- on /cancel. Set means it no longer renews; /account shows the date.
ALTER TABLE users ADD COLUMN cancel_at TEXT;
