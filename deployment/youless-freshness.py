#!/usr/bin/env python3
"""Check that every youless node is still writing rows to its own database.

The systemd watchdog in youless.service catches the reader's loop stalling. It
cannot catch the cases where the loop turns fine but data still is not landing:
database unreachable or refusing writes, disk full, the daemon killed and not
restarted, or the whole host down. That is what this covers.

Both checks were added after capture on pi4 sat dead for 98 days (2026-05-18 to
2026-08-24) while systemd reported the unit as "active (running)".

Written against psycopg2 rather than psql because pi4 has no postgresql-client
package installed, while both nodes already have python3 + psycopg2.

Install as /usr/local/sbin/youless-freshness.py (mode 0755), with config in
/etc/youless/freshness.env:

    PGUSER=tsdb
    PGPASSWORD=<secret>
    PGDATABASE=timescale
    NODES="localhost pi4"
    MAX_LAG_SECONDS=300

Exit 0 = every node fresh. Exit 1 = at least one node stale or unreachable, so
systemd records the unit as failed and `systemctl --failed` shows it.
"""

import os
import sys

import psycopg2
from psycopg2 import sql


def main() -> int:
    nodes = os.getenv("NODES", "localhost").split()
    max_lag = int(os.getenv("MAX_LAG_SECONDS", "300"))
    table = os.getenv("TABLE", "data")
    user = os.getenv("PGUSER", "tsdb")
    dbname = os.getenv("PGDATABASE", "timescale")
    password = os.getenv("PGPASSWORD")
    connect_timeout = int(os.getenv("CONNECT_TIMEOUT", "10"))

    failed = False

    for node in nodes:
        try:
            conn = psycopg2.connect(
                host=node,
                user=user,
                dbname=dbname,
                password=password,
                connect_timeout=connect_timeout,
            )
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        sql.SQL(
                            "SELECT EXTRACT(EPOCH FROM now() - max(tm))::bigint FROM {}"
                        ).format(sql.Identifier(table))
                    )
                    row = cur.fetchone()
            finally:
                conn.close()
        except Exception as e:
            # Collapse newlines so each node stays one journal line.
            detail = " ".join(str(e).split())
            print(f"CRITICAL {node}: cannot query {table}: {detail}")
            failed = True
            continue

        lag = row[0] if row else None

        if lag is None:
            print(f"CRITICAL {node}: {table} is empty")
            failed = True
        elif lag > max_lag:
            print(
                f"CRITICAL {node}: newest row is {lag}s old "
                f"(limit {max_lag}s) -- capture has stopped"
            )
            failed = True
        else:
            print(f"OK {node}: newest row {lag}s old")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
