import argparse
import logging as log
import os

import psycopg2
from psycopg2 import sql

log.basicConfig(format="%(asctime)s - %(message)s", level=log.INFO)


def _get_dsn(value: str | None, env_key: str) -> str:
    dsn = value or os.getenv(env_key)
    if not dsn:
        raise ValueError(f"{env_key} environment variable is not set")
    return dsn


def _column_names(cursor) -> list[str]:
    return [desc[0] for desc in cursor.description]


def _split_table_name(table: str) -> tuple[str, str]:
    if "." in table:
        schema, name = table.split(".", 1)
        return schema, name
    return "public", table


def _generated_columns(cursor, table: str) -> set[str]:
    schema, name = _split_table_name(table)
    cursor.execute(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s AND is_generated = 'ALWAYS'
        """,
        (schema, name),
    )
    return {row[0] for row in cursor.fetchall()}


def _identity_or_serial_columns(cursor, table: str) -> set[str]:
    schema, name = _split_table_name(table)
    cursor.execute(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
          AND (
            identity_generation IS NOT NULL
            OR column_default LIKE 'nextval(%%'
          )
        """,
        (schema, name),
    )
    return {row[0] for row in cursor.fetchall()}

def sync_missing_rows(
    source_dsn: str,
    target_dsn: str,
    table: str = "data",
    batch_size: int = 500,
) -> int:
    src_conn = None
    tgt_conn = None
    src_cursor = None
    tgt_cursor = None
    inserted = 0

    log.info("Starting sync of %s from %s to %s", table, source_dsn, target_dsn)
    try:
        src_conn = psycopg2.connect(source_dsn)
        tgt_conn = psycopg2.connect(target_dsn)

        src_cursor = src_conn.cursor(name="src_cursor")
        src_cursor.itersize = batch_size
        src_cursor.execute(
            sql.SQL("SELECT * FROM {} ORDER BY tm DESC").format(sql.Identifier(table))
        )

        first_row = src_cursor.fetchone()
        if first_row is None:
            log.info("No rows found in %s; nothing to sync.", table)
            return 0

        columns = _column_names(src_cursor)
        if not columns:
            raise ValueError(f"Could not read column metadata for {table}")
        if "tm" not in columns:
            raise ValueError(f"Column 'tm' not found in {table}")

        gen_cursor = tgt_conn.cursor()
        try:
            generated = _generated_columns(gen_cursor, table)
            generated_by_default = _identity_or_serial_columns(gen_cursor, table)
        finally:
            gen_cursor.close()

        excluded = generated | generated_by_default
        if excluded:
            log.info("Excluding columns from insert: %s", ", ".join(sorted(excluded)))
        insert_columns = [col for col in columns if col not in excluded]
        if not insert_columns:
            raise ValueError(f"No insertable columns found for {table}")

        tm_index = columns.index("tm")
        insert_indices = [columns.index(col) for col in insert_columns]
        cols_sql = sql.SQL(", ").join(map(sql.Identifier, insert_columns))
        placeholders = sql.SQL(", ").join(sql.Placeholder() * len(insert_columns))
        insert_stmt = sql.SQL(
            "INSERT INTO {} ({}) SELECT {} "
            "WHERE NOT EXISTS (SELECT 1 FROM {} WHERE tm = %s)"
        ).format(sql.Identifier(table), cols_sql, placeholders, sql.Identifier(table))

        tgt_cursor = tgt_conn.cursor()
        processed = 0

        row = first_row
        while row is not None:
            values = [row[i] for i in insert_indices]
            tgt_cursor.execute(insert_stmt, (*values, row[tm_index]))
            if tgt_cursor.rowcount:
                inserted += 1
                if inserted % batch_size == 0 or inserted < 10:
                    log.info(f"just inserted {row}")
            processed += 1

            if processed % batch_size == 0:
                tgt_conn.commit()
                log.info("Processed %s rows, inserted %s so far", processed, inserted)

            row = src_cursor.fetchone()

        tgt_conn.commit()
        log.info("Finished. Processed %s rows, inserted %s", processed, inserted)
        return inserted
    finally:
        if src_cursor:
            src_cursor.close()
        if tgt_cursor:
            tgt_cursor.close()
        if src_conn:
            src_conn.close()
        if tgt_conn:
            tgt_conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Sync rows from source to target where tm is missing in target."
    )
    parser.add_argument("--source-dsn", help="Source DSN (or set PG_DSN_SOURCE).")
    parser.add_argument("--target-dsn", help="Target DSN (or set PG_DSN_TARGET).")
    parser.add_argument("--table", default="data", help="Table name (default: data).")
    parser.add_argument("--batch-size", type=int, default=500)
    args = parser.parse_args()

    source_dsn = _get_dsn(args.source_dsn, "PG_DSN_SOURCE")
    target_dsn = _get_dsn(args.target_dsn, "PG_DSN_TARGET")

    sync_missing_rows(
        source_dsn=source_dsn,
        target_dsn=target_dsn,
        table=args.table,
        batch_size=args.batch_size,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
