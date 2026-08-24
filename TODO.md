# TODO

Open items, most-worth-doing first within each group. Detail below the index.

| # | Item | Group |
|---|------|-------|
| 1 | [Add the freshness check to the deploy pipeline](#1-add-the-freshness-check-to-the-deploy-pipeline) | code |
| 2 | [Make the freshness check actually reach someone](#2-make-the-freshness-check-actually-reach-someone) | code |
| 3 | [Reuse the database connection in the DAO](#3-reuse-the-database-connection-in-the-dao) | code |
| 4 | [Repo SQL is stale vs the deployed dashboard](#4-repo-sql-is-stale-vs-the-deployed-dashboard) | repo |
| 5 | [Scratch SQL still holds the slow bucket_minmax queries](#5-scratch-sql-still-holds-the-slow-bucket_minmax-queries) | repo |
| 6 | [Deploy 72da7c2](#6-deploy-72da7c2) | ops |
| 7 | [Confirm graceful shutdown on the next deploy](#7-confirm-graceful-shutdown-on-the-next-deploy) | ops |
| 8 | [Check the monthly aggregate on 1 September](#8-check-the-monthly-aggregate-on-1-september) | ops |
| 9 | [pi4 is 82% full](#9-pi4-is-82-full) | ops |
| 10 | [Jenkins GUI is slow over the tunnel](#10-jenkins-gui-is-slow-over-the-tunnel) | ops |
| 11 | [Untracked files](#11-untracked-files) | housekeeping |
| 12 | [Second Jenkins job: youless_reader](#12-second-jenkins-job-youless_reader) | housekeeping |
| 13 | [Grafana service-account token](#13-grafana-service-account-token) | housekeeping |

Known and accepted, no action planned: [historical duplicates](#historical-duplicate-timestamps),
[meter sample skips](#meter-sample-skips). Recently done: [winkinfo removal](#done).

---

## 1. Add the freshness check to the deploy pipeline

`deployment/youless-freshness.py`, `systemd/youless-freshness.service` and
`systemd/youless-freshness.timer` are **hand-installed** on patricia and pi4
(2026-08-24). `deployment/deploy_youless.sh` does not know about them, so a
rebuilt or newly added node silently comes up with no capture monitoring at all
-- exactly the blind spot that let pi4 sit dead for 98 days.

What the deploy script needs, alongside what it already installs:

```sh
install -m 0755 -D "${SRC_DIR}/deployment/youless-freshness.py" /usr/local/sbin/youless-freshness.py
install -m 0644    "${SRC_DIR}/systemd/youless-freshness.service" /etc/systemd/system/
install -m 0644    "${SRC_DIR}/systemd/youless-freshness.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now youless-freshness.timer
```

### Gotchas

- **`/etc/youless/freshness.env` holds the database password** and must stay out
  of the repo. The deploy must not overwrite it -- create only when absent, or
  leave it to manual provisioning like `/etc/youless/youless.env`.
- **The env file is node-specific.** Each node checks itself *and* its peer:
  patricia has `NODES="localhost pi4"`, pi4 has `NODES="localhost patricia"`.
  So it cannot be one shared template; either derive `NODES` from the local
  hostname at install time, or keep provisioning by hand.
- `enable --now` is only needed on first install but is idempotent.
- The script's `find "${APP_DIR}" -mindepth 1 -type f -delete` only clears
  `/opt/youless`; it does not touch `/usr/local/sbin` or `/etc/systemd/system`.
- No sudoers change needed -- the existing rule grants the whole script, which
  already runs as root.

## 2. Make the freshness check actually reach someone

`youless-freshness.service` writes `CRITICAL ...` to the local journal and exits
non-zero, so failures show in `systemctl --failed` and
`journalctl -u youless-freshness`. Both are **pull** signals: they only help if
somebody looks. The pi4 outage went unnoticed for 98 days precisely because
nothing pushed.

Add an `OnFailure=` unit that sends somewhere that reaches a phone -- ntfy,
Pushover, email, a Telegram bot.

The two nodes cross-check each other, so whichever is alive can raise the alarm
about the other. A single central alerting path is fine; it need not be
per-node.

### Related, not yet covered

Nothing monitors **replica divergence**. Both nodes can be individually fresh
while drifting apart -- as pi4 did for 15 months before the 2026-08-24 backfill.
A periodic per-month row-count comparison (what `data_sync.py --dry-run` already
prints) would catch it.

## 3. Reuse the database connection in the DAO

`Dao.add()` in `src/youless_dao_postgres.py` calls `psycopg2.connect()` for
every single row -- a fresh TCP connection, auth handshake and teardown once per
10-second sample, forever. `youless_reader.py` has the same pattern on the HTTP
side: no `requests.Session`, so each poll opens a new connection to the meter,
and it polls every 0.3s while waiting.

Neither is a throughput problem at one row per 10 seconds, but both are pure
overhead and the database one costs the Pi real CPU for nothing.

Not done yet because it is **not a drop-in change**: a long-lived connection
needs reconnect-on-failure handling, or the daemon wedges the first time the
database restarts or the network blips. Get that wrong and it becomes another
silent-stall failure mode -- exactly what the watchdog was added to catch. Worth
doing carefully, with the watchdog now in place as a backstop.

## 4. Repo SQL is stale vs the deployed dashboard

`grafana/prod/*.sql` still show the old `SET TIME ZONE 'Europe/Amsterdam'` style
and pre-guard predicates. The live dashboard is at **v60**, where every panel is
session-timezone independent via `now() AT TIME ZONE` and carries the chunk-prune
guard.

Grafana keeps its own copy of every panel query in `grafana.db`, so these files
are documentation, not a deployment path. Right now they document something that
no longer exists. Export the live panel SQL back into the repo, or update by
hand.

## 5. Scratch SQL still holds the slow bucket_minmax queries

`grafana/current_year.sql`, `grafana/last_n_days.sql`,
`grafana/measure_query_time.sql` and the top halves of the `prod/` files still
contain the `generate_series` + self-join `bucket_minmax` pattern.

Nothing live uses them -- verified against parsed dashboard rows. But compression
made that shape substantially **slower** (6,530 ms -> 14,274 ms for the 20-month
variant), so as reference material they are now actively misleading. Delete or
clearly mark superseded.

## 6. Deploy 72da7c2

The startup-banner change (`log.error` -> `log.info`) is committed and pushed but
**not deployed**: both nodes still run `5dee2c8` from disk. Until deployed, every
restart still logs a red `ERROR` line that is not an error.

Does not warrant a deploy of its own -- let it ride with the next one.

## 7. Confirm graceful shutdown on the next deploy

Both nodes now run code where the "capture one more sample, then exit" logic
actually exists. It had been committed in `adba7cb` (1 February) and never
deployed; patricia was running a build with no signal handler at all and died on
an uncaught `KeyboardInterrupt`, pi4 a build that checked the flag at the top of
the loop and exited before polling.

The next deploy should log `exit requested, exiting now`. Nothing to change --
just watch for that line:

```sh
journalctl -u youless.service -f -o short-precise --since now
```

## 8. Check the monthly aggregate on 1 September

`monthly_energy_summary` contains a **partial August bucket**, materialised by
the initial full refresh during the 2026-08-24 rebuild. Panels exclude the
current month, so nothing reads it before September.

On 1 September between 00:00 and ~01:00 the August bar would read low until the
hourly refresh policy corrects it. Self-healing; worth one glance.

## 9. pi4 is 82% full

46G used of 59G, 10G free. The winkinfo journal cleanup recovered 5G, but ~45G
on that card is still unaccounted for and is not youless (77M compressed today,
growing roughly 5M a month).

Not urgent at 10G free. Worth identifying before it becomes urgent, especially
now that pi4 holds a full replica.

## 10. Jenkins GUI is slow over the tunnel

Jenkins itself is fine: `/login` in 39 ms and a job page in 6 ms measured on
patricia, load average 0.11, 4.6G RAM free.

The cost is the path. Measured 2026-08-25: 20 sequential requests took **202 ms
on patricia and 2,642 ms through the tunnel** -- 10 ms vs 132 ms per request,
a 13x penalty. A Jenkins page is dozens of round trips, so it compounds.

Two causes: the hop goes laptop -> internet -> `sprenkelshosting.nl:8022` ->
patricia, and an `ssh -L` tunnel is a **single TCP connection**, so all parallel
asset loads share one congestion window and suffer head-of-line blocking.

Mitigations, cheapest first:

```sh
ssh -C -N -L 8080:localhost:8080 patricia    # compression
```

```
# ~/.ssh/config, under Host patricia
ControlMaster auto
ControlPath ~/.ssh/cm-%r@%h:%p
ControlPersist 10m
```

Best fix is to skip the GUI: an API token plus `curl` from patricia is one round
trip instead of hundreds.

## 11. Untracked files

- `data/youless.data` -- binary SQLite from the old implementation. Gitignore
  rather than commit.
- `.aiignore`, `notes_youless.txt` -- pre-existing; decide to track or ignore.

## 12. Second Jenkins job: youless_reader

A second job on the same repo alongside `youless_pipeline`. Unclear whether it is
still wanted. Delete if not.

## 13. Grafana service-account token

Created 2026-08-24 for the dashboard API work, still active, with the token in
`~/.grafana_token` on patricia. Revoke both if it was only for that.

---

## Known and accepted

### Historical duplicate timestamps

28 duplicate `tm` values between 2025-08 and 2026-01, 56 rows with 33 distinct
payloads. **Prevention is fixed and proven** -- the reader now seeds its
duplicate check from the database on startup, and the 2026-08-24 deploy restart
produced zero new duplicates.

The historical rows are not deduped: they sit in compressed chunks, and a unique
index on `tm` is not supported on a compressed hypertable. `data_sync.py` does
not need one -- its anti-join handles duplicates.

### Meter sample skips

The YouLess itself drops roughly 4 samples per 2 hours. Both nodes record the
**identical** gaps, which proves it is the meter and not the capture. Redundancy
cannot help. Harmless for energy totals, which are cumulative counters; it shows
only as a one-sample hole in the `pwr` series.

---

## Done

- **2026-08-24 -- removed `winkinfo.service` from pi4.** Dead unit crash-looping
  at `status=217/USER` (its user no longer existed), 1,864,455 restarts, ~1 every
  5 seconds, generating 3,434 journal lines an hour against youless's 382.
  Removed unit, symlink and `/opt/winkinfo`; vacuumed journals 3.9G -> 472M and
  capped `SystemMaxUse=500M`. Disk went 92% -> 82%, freeing 5G.
