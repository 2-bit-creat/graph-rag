CREATE TABLE IF NOT EXISTS usage_counters (
    user_id UUID NOT NULL,
    day DATE NOT NULL,
    kind TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, day, kind)
);
CREATE INDEX IF NOT EXISTS idx_usage_counters_day ON usage_counters (day);
