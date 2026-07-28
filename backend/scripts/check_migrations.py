"""CI-only validator for versioned, expand-compatible schema migrations."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.db import migration_checksum, validate_migration_sql, versioned_migration_files


def main() -> int:
    for path in versioned_migration_files():
        sql = path.read_text(encoding="utf-8")
        validate_migration_sql(sql)
        print(f"{path.name}: {migration_checksum(sql)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
