ALTER TABLE temporal_backfill_audits
    ADD CONSTRAINT temporal_backfill_audits_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE temporal_backfill_audits
    ADD CONSTRAINT temporal_backfill_audits_node_id_fkey
    FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;
