#!/usr/bin/env python3
"""Sync rows from a source `data` table to a target, filling in whatever the
target is missing.

Set-based and month-scoped. It compares per-month row counts on both sides and,
for each month where the source has more rows, streams just that month with
COPY into a staging table on the target and fills the gap with a single
anti-join INSERT.

This replaces a row-at-a-time implementation that issued one
`INSERT ... WHERE NOT EXISTS (SELECT 1 FROM data WHERE tm = %s)` round-trip per
source row. That was slow by design, but the reason it never finished was that
the target's `data` table had no index on `tm`, so every one of those probes was
a full sequential scan. Make sure the target is indexed (or a hypertable) before
running this -- see deployment/perf-003-replica-prep.sql.

Compressed chunks on the target are decompressed just before rows are inserted
into them and compressed again afterwards. A month that fails is logged and
skipped; the remaining months still run, and the exit status is 1 if any month
failed.

DSNs come from --source-dsn/--target-dsn or, failing that, the environment:
PG_DSN_FROM / PG_DSN_TO (as written in data_sync.env), with
PG_DSN_SOURCE / PG_DSN_TARGET accepted as aliases.
"""

import argparse
import datetime
import logging as log
import os
import re
import tempfile

import psycopg2
from psycopg2 import sql

log.basicConfig(format="%(asctime)s %(levelname)-5s %(message)s", level=log.INFO)

# Keep the COPY buffer in memory up to this size, then spill to a temp file.
SPOOL_MAX_BYTES = 64 * 1024 * 1024


class SyncIncomplete(Exception):
    """Raised after all months were tried, when at least one of them failed."""

    def __init__(self, inserted: int, failed: list):
        super().__init__(f"{len(failed)} month(s) failed")
        self.inserted = inserted
        self.failed = failed


def _get_dsn(value: str | None, *env_keys: str) -> str:
    if value:
        return value
    for key in env_keys:
        dsn = os.getenv(key)
        if dsn:
            return dsn
    raise SystemExit(f"No DSN given. Set one of {' / '.join(env_keys)}.")


def _redact(dsn: str) -> str:
    """DSNs carry the database password; never log them verbatim."""
    return re.sub(r"(password\s*=\s*)\S+", r"\1***", dsn)


def _columns(conn, table: str) -> list[str]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT attname FROM pg_attribute "
            "WHERE attrelid = %s::regclass AND attnum > 0 AND NOT attisdropped "
            "ORDER BY attnum",
            (table,),
        )
        return [r[0] for r in cur.fetchall()]


def _self_managed_columns(conn, table: str) -> set[str]:
    """Columns the target computes for itself, which must be left out of the
    insert.

    On this pair that is `uid` and `id`. `uid` is GENERATED ALWAYS, but with a
    different expression per node -- 'A' || id on patricia, 'B' || id on pi4 --
    so it is a deliberate per-database marker, not data to replicate. `id`
    comes from each node's own sequence. Copying either across would defeat the
    design (and Postgres refuses the generated one outright).
    """
    schema, name = ("public", table)
    if "." in table:
        schema, name = table.split(".", 1)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
              AND (is_generated = 'ALWAYS'
                   OR is_identity = 'YES'
                   OR column_default LIKE 'nextval(%%')
            """,
            (schema, name),
        )
        return {r[0] for r in cur.fetchall()}


def _month_counts(conn, table: str) -> dict:
    with conn.cursor() as cur:
        cur.execute(
            sql.SQL("SELECT date_trunc('month', tm), count(*) FROM {} GROUP BY 1").format(
                sql.Identifier(table)
            )
        )
        return dict(cur.fetchall())


def _hypertable_schema(conn, table: str) -> str | None:
    """Schema of `table` if it is a TimescaleDB hypertable, else None. A plain
    table (pi4 was one until perf-003) has no chunks to worry about."""
    schema, name = ("public", table)
    if "." in table:
        schema, name = table.split(".", 1)
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('timescaledb_information.hypertables') IS NOT NULL")
        if not cur.fetchone()[0]:
            return None
        cur.execute(
            "SELECT 1 FROM timescaledb_information.hypertables "
            "WHERE hypertable_schema = %s AND hypertable_name = %s",
            (schema, name),
        )
        return schema if cur.fetchone() else None


def _compressed_chunks_for(cur, schema: str, table: str) -> list[str]:
    """Compressed chunks that would receive at least one row of `missing`."""
    name = table.split(".", 1)[-1]
    cur.execute(
        """
        SELECT format('%%I.%%I', c.chunk_schema, c.chunk_name)
        FROM timescaledb_information.chunks c
        WHERE c.hypertable_schema = %s AND c.hypertable_name = %s
          AND c.is_compressed
          AND EXISTS (SELECT 1 FROM missing m
                      WHERE m.tm >= c.range_start AND m.tm < c.range_end)
        ORDER BY c.range_start
        """,
        (schema, name),
    )
    return [r[0] for r in cur.fetchall()]


def _sync_month(src, tgt, table, cols, start, end, hyper_schema=None) -> int:
    """Copy the rows of [start, end) that the target lacks. Returns the number
    inserted.

    Inserting straight into a compressed chunk failed on patricia (TODO 18:
    `DatatypeMismatch: attribute 11 of type record has wrong type`), so any
    compressed chunk that is about to receive rows is decompressed first, in
    the same transaction as the INSERT, and compressed again afterwards. Chunks
    with nothing missing are never touched, so a month that only *looks*
    behind costs nothing extra.
    """
    collist = sql.SQL(", ").join(map(sql.Identifier, cols))
    ident = sql.Identifier(table)

    with tempfile.SpooledTemporaryFile(max_size=SPOOL_MAX_BYTES, mode="w+b") as buf:
        with src.cursor() as sc:
            sc.copy_expert(
                sql.SQL(
                    "COPY (SELECT {cols} FROM {tbl} WHERE tm >= {a} AND tm < {b}) TO STDOUT"
                )
                .format(cols=collist, tbl=ident, a=sql.Literal(start), b=sql.Literal(end))
                .as_string(src),
                buf,
            )
        src.rollback()  # read-only; don't leave the source idle in a transaction
        buf.seek(0)
        with tgt.cursor() as tc:
            tc.execute(
                sql.SQL("CREATE TEMP TABLE stage (LIKE {}) ON COMMIT DROP").format(ident)
            )
            tc.copy_expert(
                sql.SQL("COPY stage ({cols}) FROM STDIN").format(cols=collist).as_string(tgt),
                buf,
            )
            # One anti-join instead of one round-trip per row. Source rows that
            # share a tm are both kept: the replica mirrors the source, warts
            # and all. Reading a compressed chunk is fine; only writing is not.
            tc.execute(
                sql.SQL(
                    "CREATE TEMP TABLE missing ON COMMIT DROP AS "
                    "SELECT {cols} FROM stage s "
                    "WHERE NOT EXISTS (SELECT 1 FROM {tbl} d WHERE d.tm = s.tm)"
                ).format(tbl=ident, cols=collist)
            )
            if tc.rowcount == 0:
                tgt.commit()
                return 0

            chunks = _compressed_chunks_for(tc, hyper_schema, table) if hyper_schema else []
            for chunk in chunks:
                log.info("    decompressing %s", chunk)
                tc.execute("SELECT decompress_chunk(%s::regclass)", (chunk,))

            tc.execute(
                sql.SQL("INSERT INTO {tbl} ({cols}) SELECT {cols} FROM missing").format(
                    tbl=ident, cols=collist
                )
            )
            inserted = tc.rowcount
    # Decompression and insert commit together: if the insert fails, the
    # chunk is still compressed and nothing was written.
    tgt.commit()

    # Recompress separately, so a failure here cannot undo the rows just
    # written. If it does fail, the compression policy picks the chunk up on
    # its next run anyway.
    for chunk in chunks:
        try:
            with tgt.cursor() as tc:
                tc.execute(
                    "SELECT compress_chunk(%s::regclass, if_not_compressed => true)", (chunk,)
                )
            tgt.commit()
            log.info("    recompressed %s", chunk)
        except psycopg2.Error as e:
            tgt.rollback()
            log.warning("    could not recompress %s (the compression policy will): %s",
                        chunk, " ".join(str(e).split()))
    return inserted


def sync_missing_rows(source_dsn, target_dsn, table="data", dry_run=False) -> int:
    log.info("source %s", _redact(source_dsn))
    log.info("target %s", _redact(target_dsn))

    src = tgt = None
    try:
        src = psycopg2.connect(source_dsn)
        tgt = psycopg2.connect(target_dsn)

        src_cols, tgt_cols = _columns(src, table), set(_columns(tgt, table))
        self_managed = _self_managed_columns(tgt, table)
        cols = [c for c in src_cols if c in tgt_cols and c not in self_managed]

        absent = [c for c in src_cols if c not in tgt_cols]
        if absent:
            log.warning("not present in target, skipping: %s", ", ".join(absent))
        if self_managed:
            log.info("target generates these itself, not copied: %s",
                     ", ".join(sorted(self_managed)))
        if "tm" not in cols:
            raise SystemExit(f"'tm' is missing from {table} on one side; cannot sync")

        s_counts, t_counts = _month_counts(src, table), _month_counts(tgt, table)
        todo = sorted(m for m in s_counts if s_counts[m] > t_counts.get(m, 0))
        gap = sum(s_counts[m] - t_counts.get(m, 0) for m in todo)

        log.info(
            "source %s rows / target %s rows -- %s month(s) behind, ~%s rows to copy",
            sum(s_counts.values()), sum(t_counts.values()), len(todo), gap,
        )
        for m in todo:
            log.info("  %s  source=%-8s target=%-8s", m.date(), s_counts[m], t_counts.get(m, 0))
        if dry_run:
            log.info("--dry-run: nothing written")
            return 0
        if not todo:
            log.info("target is up to date")
            return 0

        hyper_schema = _hypertable_schema(tgt, table)
        tgt.commit()

        # Months run oldest first. One failing month must not stop the rest:
        # on 2026-09-20 a failure in 2026-05 meant 2026-09, the month that
        # mattered, was never reached (TODO 18).
        total, failed = 0, []
        for i, m in enumerate(todo, 1):
            end = (m.replace(day=1) + datetime.timedelta(days=32)).replace(day=1)
            try:
                n = _sync_month(src, tgt, table, cols, m, end, hyper_schema)
            except psycopg2.Error as e:
                for c in (src, tgt):
                    try:
                        c.rollback()
                    except psycopg2.Error:
                        pass
                failed.append(m)
                log.error("[%s/%s] %s: FAILED, nothing written for this month: %s: %s",
                          i, len(todo), m.date(), type(e).__name__, " ".join(str(e).split()))
                continue
            total += n
            log.info("[%s/%s] %s: inserted %s (running total %s)", i, len(todo), m.date(), n, total)

        if failed:
            log.error("done -- inserted %s rows; %s month(s) FAILED: %s", total, len(failed),
                      ", ".join(str(m.date()) for m in failed))
            raise SyncIncomplete(total, failed)
        log.info("done -- inserted %s rows", total)
        return total
    finally:
        for c in (src, tgt):
            if c:
                c.close()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--source-dsn", help="source DSN (else PG_DSN_FROM / PG_DSN_SOURCE)")
    p.add_argument("--target-dsn", help="target DSN (else PG_DSN_TO / PG_DSN_TARGET)")
    p.add_argument("--table", default="data")
    p.add_argument("--dry-run", action="store_true", help="report the plan, write nothing")
    a = p.parse_args()

    try:
        sync_missing_rows(
            _get_dsn(a.source_dsn, "PG_DSN_FROM", "PG_DSN_SOURCE"),
            _get_dsn(a.target_dsn, "PG_DSN_TO", "PG_DSN_TARGET"),
            table=a.table,
            dry_run=a.dry_run,
        )
    except SyncIncomplete:
        return 1  # already logged; non-zero so a caller or timer notices
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
