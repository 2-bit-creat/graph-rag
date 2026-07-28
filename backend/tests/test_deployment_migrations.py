from __future__ import annotations

import pytest

from app.db import migration_checksum, validate_migration_sql


@pytest.mark.parametrize(
    "sql",
    [
        "CREATE TABLE IF NOT EXISTS deployment_test (id UUID)",
        "CREATE INDEX IF NOT EXISTS idx_deployment_test_id ON deployment_test (id)",
        "ALTER TABLE deployment_test ADD COLUMN IF NOT EXISTS note TEXT",
    ],
)
def test_additive_migrations_are_allowed(sql: str) -> None:
    validate_migration_sql(sql)


@pytest.mark.parametrize(
    "sql",
    [
        "DROP TABLE deployment_test",
        "TRUNCATE deployment_test",
        "ALTER TABLE deployment_test RENAME COLUMN note TO description",
        "ALTER TABLE deployment_test ADD COLUMN required TEXT NOT NULL",
        "UPDATE deployment_test SET note = 'backfill'",
    ],
)
def test_unsafe_migrations_are_rejected(sql: str) -> None:
    with pytest.raises(ValueError):
        validate_migration_sql(sql)


def test_migration_checksum_is_stable_and_content_sensitive() -> None:
    assert migration_checksum("CREATE TABLE a (id INT)") == migration_checksum("CREATE TABLE a (id INT)")
    assert migration_checksum("CREATE TABLE a (id INT)") != migration_checksum("CREATE TABLE a (id BIGINT)")
