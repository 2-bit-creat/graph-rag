from __future__ import annotations

import pytest

from app.db import (
    is_transient_database_error,
    migration_checksum,
    split_sql_statements,
    validate_migration_sql,
)
from app.models import Node
from app.quiz_generation_runs import _RUN_STALE_AFTER


def test_node_writes_legacy_pin_column_as_false() -> None:
    """Old production schemas require is_pinned even though pinning is retired."""
    column = Node.__table__.c.is_pinned
    assert column.nullable is False
    assert column.default is not None
    assert column.default.arg is False


def test_database_recovery_error_is_retryable() -> None:
    cause = RuntimeError("the database system is in recovery mode")
    wrapped = RuntimeError("database request failed")
    wrapped.__cause__ = cause
    assert is_transient_database_error(wrapped)
    assert not is_transient_database_error(RuntimeError("invalid input syntax"))


def test_generation_run_stale_window_is_longer_than_one_request() -> None:
    assert _RUN_STALE_AFTER.total_seconds() == 15 * 60


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


def test_split_sql_statements_separates_multiple_commands() -> None:
    sql = """
    ALTER TABLE nodes ADD COLUMN IF NOT EXISTS a TEXT;
    ALTER TABLE nodes ADD COLUMN IF NOT EXISTS b TEXT DEFAULT 'x';
    CREATE INDEX IF NOT EXISTS idx_nodes_a ON nodes (a);
    """
    assert split_sql_statements(sql) == [
        "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS a TEXT",
        "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS b TEXT DEFAULT 'x'",
        "CREATE INDEX IF NOT EXISTS idx_nodes_a ON nodes (a)",
    ]


def test_split_sql_statements_ignores_semicolons_inside_quotes_and_dollar_blocks() -> None:
    sql = """
    ALTER TABLE nodes ADD COLUMN IF NOT EXISTS note TEXT DEFAULT 'a;b';
    DO $$
    BEGIN
        IF EXISTS (SELECT 1) THEN
            RAISE NOTICE 'semi;colon';
        END IF;
    END $$;
    """
    statements = split_sql_statements(sql)
    assert len(statements) == 2
    assert statements[0] == "ALTER TABLE nodes ADD COLUMN IF NOT EXISTS note TEXT DEFAULT 'a;b'"
    assert statements[1].startswith("DO $$") and statements[1].endswith("END $$")
