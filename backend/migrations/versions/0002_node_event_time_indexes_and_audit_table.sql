CREATE INDEX IF NOT EXISTS idx_nodes_user_event_start ON nodes (user_id, event_start_at);
CREATE INDEX IF NOT EXISTS idx_nodes_user_event_status ON nodes (user_id, event_status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_statement_claim_key ON nodes (user_id, claim_key) WHERE type = 'Statement' AND claim_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS temporal_backfill_audits (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    node_id UUID NOT NULL,
    before JSONB NOT NULL,
    after JSONB NOT NULL,
    run_key TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_temporal_backfill_audits_user_created ON temporal_backfill_audits (user_id, created_at DESC);
