ALTER TABLE usage_counters
    ADD CONSTRAINT usage_counters_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
