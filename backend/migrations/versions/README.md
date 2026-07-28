# Versioned production migrations

Add one `NNNN_description.sql` file per deployable schema change. Automatic
migrations permit only additive `CREATE TABLE`, `CREATE INDEX`, and `ALTER TABLE
... ADD COLUMN|ADD CONSTRAINT` statements. Destructive changes, renames, and
data backfills require the operational migration runbook.
