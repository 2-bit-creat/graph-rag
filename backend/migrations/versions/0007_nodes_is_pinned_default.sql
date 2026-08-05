-- Legacy production schemas can have this retired compatibility column without
-- a server default. Inserts that omit it then violate its NOT NULL constraint.
-- This changes only future writes; existing data is untouched.
ALTER TABLE nodes ALTER COLUMN is_pinned SET DEFAULT FALSE;
