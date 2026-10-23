-- The visitor salt (src/lib/visitor-salt.ts): one random value per UTC day, so a visitor id (v_…) joins page views,
-- downloads and app sign-ins within that day and never across days. A day's salt is deleted once the next day is
-- over (at most 48 h after it was made); without it nobody, us included, can tell whose id it was.
-- 0007, not 0004: 0004-0006 are taken by other branches.
CREATE TABLE visitor_salts (
  day TEXT PRIMARY KEY, -- YYYY-MM-DD, UTC
  salt TEXT NOT NULL    -- 32 random bytes, hex
);
