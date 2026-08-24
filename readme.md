# youless

Reads time-series data from a YouLess LS120 energy meter and visualises it in
Grafana.

**Setting up a new machine? See [INSTALL.md](INSTALL.md).** That is the
authoritative runbook; this file is an overview. Install steps used to live here
too and drifted out of date, so they now live in exactly one place.

## How it works

A small Python daemon polls the meter's JSON endpoint (`http://192.168.2.12/e`)
and writes every new sample into a local TimescaleDB. Grafana queries that
database.

```
YouLess LS120  --HTTP-->  youless_reader.py  --INSERT-->  TimescaleDB  <--  Grafana
```

The meter emits a new reading roughly every 10 seconds. The reader polls
quickly (0.3s) while waiting for the timestamp to change, then sleeps ~9.5s once
it has stored one, staying in step with the meter rather than drifting.

### Redundancy

There are **two independent nodes**, `patricia` and `pi4`. Each polls the meter
itself and writes to its own database. Neither depends on the other, so a deploy
or an outage on one does not interrupt capture on the other.

They are kept in step by `src/tools/data_sync.py`, which compares per-month row
counts and backfills only what is missing.

### Keeping it honest

Two independent mechanisms, because they catch different failures:

- **A systemd watchdog** (`WatchdogSec=60`). The reader pings once per loop
  iteration; if the loop stops turning, systemd restarts it. This exists because
  the reader once blocked forever in `recvfrom()` on a half-open socket to the
  meter, while systemd still reported the unit `active (running)` -- capture was
  dead for 98 days and nothing noticed.
- **A freshness check** (`youless-freshness.py`, on a 5-minute timer). Each node
  verifies that every node is still *storing rows*. The watchdog cannot see a
  reader that runs fine while the database is unreachable; this can.

## Layout

| Path | What |
|---|---|
| `src/youless_reader.py` | the polling daemon |
| `src/youless_dao_postgres.py` | database writes; verifies schema at startup |
| `src/tools/data_sync.py` | backfills a node from a peer |
| `deployment/schema.sql` | authoritative database schema |
| `deployment/perf-*.sql` | applied migrations, with measurements |
| `deployment/deploy_youless.sh` | privileged deploy helper Jenkins calls |
| `deployment/youless-freshness.py` | capture monitoring |
| `systemd/` | unit files |
| `grafana/` | panel queries (see caveat in TODO.md) |
| `INSTALL.md` | fresh-node runbook |
| `TODO.md` | open work, with a status column |

## Deploying

Push to `main`, then run the `youless_pipeline` job in Jenkins with
`DEPLOY_TARGET` set to a node label (`pi` or `patricia`).

**Deploy one node at a time and verify before the next.** They are independent,
so this keeps capture alive if a release misbehaves.

## Operating it

```sh
# follow the log (microsecond timestamps; the default second granularity hides
# fast shutdown sequences)
journalctl -u youless.service -f -o short-precise

# is it healthy?
systemctl show youless.service -p ActiveState -p NRestarts -p WatchdogTimestamp

# is it actually storing data? lag should be under ~15s
psql -h localhost -U tsdb -d timescale -c \
  "SELECT count(*), max(tm), now()-max(tm) AS lag FROM data;"

# run the freshness check by hand
sudo systemctl start youless-freshness.service
journalctl -u youless-freshness.service -n 5 --no-pager
```

A clean restart logs `Received signal 2`, one final `datagram:`, then
`exit requested, exiting now` -- it captures a last sample before exiting, so a
restart costs no data.

## Notes

- The meter address is **hardcoded** in `src/youless_reader.py`, not configured.
- The daemon runs as `User=daemon`. Earlier versions of this file said to create
  a `youless` user; that account exists on the current nodes but nothing runs as
  it.
- `PG_DSN` comes from `/etc/youless/youless.env`, which is not in git.
- Meter readings are cumulative counters, so a dropped sample does not affect
  any daily or monthly total -- it shows only as a gap in the `pwr` series.
