ALTER TABLE push_subscriptions
    ADD CONSTRAINT push_subscriptions_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
