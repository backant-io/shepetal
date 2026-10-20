-- The apps sign in with OAuth for native apps and PKCE (RFC 8252, RFC 7636), see API.md.
-- This replaces the device login.
DROP TABLE device_codes;

-- One-time codes from GET /app/login, spent by the first POST /api/app/token within 60 s.
-- Only the SHA-256 hex of the code is stored, with what the token request must match.
CREATE TABLE app_codes (
  code_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL REFERENCES users (email),
  code_challenge TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

-- App tokens die after 90 days without use (API.md). NULL means not used since created_at.
ALTER TABLE tokens ADD COLUMN last_used_at TEXT;
