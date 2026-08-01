ALTER TABLE quiz_audio_links
    ADD CONSTRAINT quiz_audio_links_quiz_id_fkey
    FOREIGN KEY (quiz_id) REFERENCES quizzes(id) ON DELETE CASCADE;
ALTER TABLE quiz_audio_links
    ADD CONSTRAINT quiz_audio_links_audio_asset_id_fkey
    FOREIGN KEY (audio_asset_id) REFERENCES quiz_audio_assets(id) ON DELETE CASCADE;
