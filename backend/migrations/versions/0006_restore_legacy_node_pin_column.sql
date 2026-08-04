-- Keep ORM reads/writes compatible across old and newly-created databases.
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS is_pinned BOOLEAN NOT NULL DEFAULT FALSE;
