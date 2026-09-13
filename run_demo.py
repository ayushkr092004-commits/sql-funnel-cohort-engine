#!/usr/bin/env python3
"""Run the full Funnel & Cohort Retention Analysis Engine in DuckDB.

Usage:  pip install duckdb && python run_demo.py
Creates funnel.duckdb, loads schema + synthetic data, then runs every
analysis query and prints the results.
"""
import re
import sys
from pathlib import Path

import duckdb

HERE = Path(__file__).parent
FILES = [
    "01_schema.sql",
    "02_seed_data.sql",
    "03_funnel_analysis.sql",
    "04_cohort_retention.sql",
    "05_engagement_metrics.sql",
]


def split_statements(sql: str):
    """Naive but sufficient splitter: strips comments, splits on ';'."""
    sql = re.sub(r"--[^\n]*", "", sql)
    return [s.strip() for s in sql.split(";") if s.strip()]


def main():
    db_path = HERE / "funnel.duckdb"
    if db_path.exists():
        db_path.unlink()
    con = duckdb.connect(str(db_path))

    for fname in FILES:
        print(f"\n{'=' * 70}\n>>> {fname}\n{'=' * 70}")
        statements = split_statements((HERE / fname).read_text())
        for stmt in statements:
            try:
                result = con.execute(stmt)
                if stmt.lstrip().upper().startswith(("SELECT", "WITH")):
                    df = result.fetchdf()
                    if len(df):
                        print(df.to_string(index=False, max_rows=15))
                        print(f"... ({len(df)} rows)\n" if len(df) > 15 else "")
            except Exception as exc:  # pragma: no cover
                print(f"FAILED:\n{stmt[:300]}\n--> {exc}")
                sys.exit(1)

    con.close()
    print("\nAll queries executed successfully.")


if __name__ == "__main__":
    main()
