CREATE TABLE IF NOT EXISTS quiz_audio_assets (
    id UUID PRIMARY KEY,
    asset_key TEXT UNIQUE NOT NULL,
    kind TEXT NOT NULL,
    storage_key TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    pending_delete_at TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS quiz_audio_links (
    id UUID PRIMARY KEY,
    quiz_id UUID NOT NULL,
    audio_asset_id UUID NOT NULL,
    role TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (quiz_id, role)
);
CREATE INDEX IF NOT EXISTS idx_quiz_audio_links_asset ON quiz_audio_links (audio_asset_id);
