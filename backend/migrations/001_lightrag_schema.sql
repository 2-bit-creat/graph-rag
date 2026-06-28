-- LightRAG incremental graph schema (reference DDL; applied via db.py init_db _MIGRATIONS)

CREATE EXTENSION IF NOT EXISTS vector;

-- nodes: semantic search + speaker linkage
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS speaker_profile_id UUID REFERENCES speaker_profiles(id) ON DELETE SET NULL;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS name_embedding vector(1536);
ALTER TABLE nodes ALTER COLUMN description TYPE TEXT;

-- edges: weighted incremental merge
ALTER TABLE edges ADD COLUMN IF NOT EXISTS weight INTEGER NOT NULL DEFAULT 1;
ALTER TABLE edges ADD COLUMN IF NOT EXISTS last_triggered_at TIMESTAMPTZ;

-- quizzes: personalized learning cards
CREATE TABLE IF NOT EXISTS quizzes (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    associated_entry_id UUID REFERENCES journal_entries(id) ON DELETE SET NULL,
    quiz_type TEXT NOT NULL,
    source_nodes UUID[],
    question_ko TEXT,
    sentence_en TEXT,
    quiz_data JSONB,
    is_solved BOOLEAN NOT NULL DEFAULT FALSE,
    next_review_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_nodes_name_embedding
    ON nodes USING ivfflat (name_embedding vector_cosine_ops) WITH (lists = 100);
