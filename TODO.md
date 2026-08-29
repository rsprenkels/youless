# TODO

Most-worth-doing first within each group. Detail below the index.

**Marking an item done:** put a `[x]` in the Status column, strike the title with
`~~ ~~`, and add a `**Done YYYY-MM-DD**` line at the top of its detail section
saying what actually happened. Keep the row and its number -- numbers are stable
so references from commits and notes do not rot.

| # | Status | Item | Group |
|---|:------:|------|-------|
| 1 | **[x]** | ~~[Add the freshness check to the deploy pipeline](#1-add-the-freshness-check-to-the-deploy-pipeline)~~ | code |
| 2 | **[x]** | ~~[Make the freshness check actually reach someone](#2-make-the-freshness-check-actually-reach-someone)~~ | code |
| 3 | [ ] | [Reuse the database connection in the DAO](#3-reuse-the-database-connection-in-the-dao) | code |
| 16 | [ ] | [Nothing monitors replica divergence](#16-nothing-monitors-replica-divergence) | code |
| 4 | [ ] | [Repo SQL is stale vs the deployed dashboard](#4-repo-sql-is-stale-vs-the-deployed-dashboard) | repo |
| 5 | [ ] | [Scratch SQL still holds the slow bucket_minmax queries](#5-scratch-sql-still-holds-the-slow-bucket_minmax-queries) | repo |
| 15 | [ ] | [Dead man's switch: nothing catches a whole-house outage](#15-dead-mans-switch-nothing-catches-a-whole-house-outage) | ops |
| 14 | **[x]** | ~~[Install the current deploy script on patricia and pi4](#14-install-the-current-deploy-script-on-patricia-and-pi4)~~ | ops |
| 6 | **[x]** | ~~[Deploy 72da7c2](#6-deploy-72da7c2)~~ | ops |
| 7 | **[x]** | ~~[Confirm graceful shutdown on the next deploy](#7-confirm-graceful-shutdown-on-the-next-deploy)~~ | ops |
| 8 | [ ] | [Check the monthly aggregate on 1 September](#8-check-the-monthly-aggregate-on-1-september) | ops |
| 9 | [ ] | [pi4 is 82% full](#9-pi4-is-82-full) | ops |
| 10 | [ ] | [Jenkins GUI is slow over the tunnel](#10-jenkins-gui-is-slow-over-the-tunnel) | ops |
| 11 | **[x]** | ~~[Untracked files](#11-untracked-files)~~ | housekeeping |
| 12 | **[x]** | ~~[Second Jenkins job: youless_reader](#12-second-jenkins-job-youless_reader)~~ | housekeeping |
| 13 | [ ] | [Grafana service-account token](#13-grafana-service-account-token) | housekeeping |

**9 open, 7 done.**

Known and accepted, no action planned: [historical duplicates](#historical-duplicate-timestamps),
[meter sample skips](#meter-sample-skips). Also done, before this list existed:
[winkinfo removal](#done).

---

## 1. Add the freshness check to the deploy pipeline

**Done 2026-08-25.** `deployment/deploy_youless.sh` now installs
`youless-freshness.py` to `/usr/local/sbin/` and both units to
`/etc/systemd/system/`, then enables the timer. A rebuilt or newly added node
comes up with monitoring instead of silently without it.

The timer is enabled **only if `/etc/youless/freshness.env` exists**. That file
holds the database password and is node-specific (`NODES` names this node and
its peers), so it stays hand-provisioned and the deploy never overwrites it. If
it is missing the deploy prints a warning and leaves the timer alone -- enabling
a unit that could only fail would train you to ignore `systemctl --failed`,
which defeats the point of having it.

Manual steps that cannot be automated are written up in **[INSTALL.md](INSTALL.md)**:
database and schema, the two secret env files, the sudoers rule, the Jenkins
agent, and the `DEPLOY_TARGET` choice in the `Jenkinsfile` (hardcoded, so a new
node needs a commit).

### Required a manual step to take effect -- since done

The pipeline changes above do nothing until the new script is installed on each
node by hand. This section used to say that step was still outstanding on
patricia and pi4. **That was stale:** both nodes were verified on 2026-08-29 to
be running the current script with the freshness timer live.

Tracked as its own row now -- **[#14](#14-install-the-current-deploy-script-on-patricia-and-pi4)**,
with the evidence -- because an open action buried inside a `[x]` item is easy to
miss, and this one silently sat done-but-unrecorded.

## 2. Make the freshness check actually reach someone

**Done 2026-08-29.** Failures now push to a phone via **ntfy**.

`youless-freshness.service` used to only write `CRITICAL ...` to the journal and
exit non-zero -- visible in `systemctl --failed` and `journalctl`, both **pull**
signals that help only if somebody looks. Nobody looked for 98 days.

What was built:

- `deployment/youless-notify.sh` -- posts the failed unit, host, timestamp and
  the last 8 journal lines to an ntfy topic. Retries 3x over ~15s, because the
  likeliest reason an alert fails to send is that the network is what broke.
  Exits non-zero if it still cannot deliver, so a notification that never
  reached a phone is itself visible in `systemctl --failed`.
- `systemd/youless-notify@.service` -- template unit, started on demand.
- `OnFailure=youless-notify@%N.service` on the freshness unit.

Use **`%N`, not `%n`**: `%n` keeps the `.service` suffix and yields a unit named
`youless-notify@youless-freshness.service.service`. Caught by testing rather
than by reading, which is also why the self-test in
[INSTALL.md](INSTALL.md) drives a real `OnFailure=` instead of starting the
notifier by hand -- the latter proves the script works but not the wiring.

Verified end to end on **both** nodes with a deliberately failing unit:
`notified ntfy about youless-notify-selftest (attempt 1)` on each.

The topic lives in `/etc/youless/notify.env`, `0600 root:root`, same topic on
both nodes, deliberately **not** in git: on the public ntfy.sh instance the
topic name is the only thing keeping strangers out.

### Why ntfy.sh and not self-hosted

Self-hosting on patricia was the original plan, and it is wrong here.
`sprenkelshosting.nl` is a **residential IP -- the same connection patricia sits
behind**, not a separate VPS. An alerter on patricia therefore cannot report
patricia dying, and pi4's alerts would be addressed to a service that died with
it. It would also need port-forwarding and TLS before the phone could receive
anything away from home.

### What this does NOT cover

Two gaps, promoted to their own rows so they are not buried in a `[x]` item:
**[#15](#15-dead-mans-switch-nothing-catches-a-whole-house-outage)** (both nodes
down) and **[#16](#16-nothing-monitors-replica-divergence)**.

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

**Done 2026-08-29.** Deployed to both nodes, builds 69 (patricia) and 70 (pi).

The banner now logs at syslog priority 6 (INFO), not ERROR:

```
INFO  root starting youless_reader, write_to_dao:True loglevel:INFO
```

Worth noting this item was **already stale when it was picked up**. Checking the
running code rather than trusting the note showed both nodes had matched repo
HEAD since an earlier deploy that day -- `youless_reader.py` at `b55f2e5` and
`youless.service` at `f093128` on both. The claim that they still ran `5dee2c8`
was simply out of date. Third such case in one session, along with
[#1](#1-add-the-freshness-check-to-the-deploy-pipeline) and
[#14](#14-install-the-current-deploy-script-on-patricia-and-pi4): a note saying
work is outstanding is evidence about the past, not about the nodes.

## 7. Confirm graceful shutdown on the next deploy

Both nodes now run code where the "capture one more sample, then exit" logic
actually exists. It had been committed in `adba7cb` (1 February) and never
deployed; patricia was running a build with no signal handler at all and died on
an uncaught `KeyboardInterrupt`, pi4 a build that checked the flag at the top of
the loop and exited before polling.

**Done 2026-08-29.** Confirmed on **both** nodes, from real Jenkins deploys:

| node | build | evidence |
|---|---|---|
| patricia | 69 | `21:11:13,486 INFO root exit requested, exiting now` |
| pi4 | 70 | `21:16:08,472 INFO root exit requested, exiting now` |

Each was followed immediately by a clean start and, on pi4,
`Connected to PostgreSQL, writing to hypertable 'data'`. No `KeyboardInterrupt`,
no traceback, `NRestarts: 0` on both.

pi4 was the one that mattered and it was confirmed last. Its earlier restarts
that day were Postgres-race crashes rather than clean stops, so nothing before
build 70 actually exercised the signal handler on that node -- patricia logging
the line proved nothing about pi4.

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

**Done 2026-08-25.** Working tree is clean; nothing untracked remains.

- `data/youless.data` -- **deleted.** Inspected first: one table `data`, **zero
  rows**, 8,192 bytes (just the SQLite header page plus an empty table page),
  dated 2025-12-22. It carried the original 14-column schema including `cs0`,
  `ps0`, `wtr`, `wts` -- the four columns since dropped from Postgres -- so it
  was a leftover skeleton from the SQLite era the readme still describes, never
  written to. That column history is already recorded in the comments of
  `deployment/schema.sql`, so nothing was lost.
- `.aiignore`, `notes_youless.txt` -- **now tracked**, committed in `4fcf697`.
  Note this was not deliberate: they were already staged (most likely by the
  IDE) when that commit was made, and `git commit` took the whole index. Both
  are small and belong in the repo -- `.aiignore` is 15 lines of tool ignore
  patterns, `notes_youless.txt` is two reference URLs plus a sample datagram,
  and neither contains anything sensitive -- so the outcome stands.

`.aiignore` still lists `data/`, which is now moot.

## 12. Second Jenkins job: youless_reader

**Done 2026-08-29.** Deleted. It was a freestyle job pointed at the same repo
with `<builders/>` empty -- it checked out `main` and did nothing else. No
triggers, no publishers, no build step. The last of its 5 builds ran on
2026-01-02, and `youless_pipeline` had long since superseded it.

Removed `/var/jenkins_home/jobs/youless_reader` inside the container, plus the
stale 9.7M agent workspace at `/var/jenkins/workspace/youless_reader{,@tmp}` on
the host, then restarted the container so the controller re-read its jobs from
disk.

The restart was the auth-free route: the Jenkins API rejects anonymous requests
with 403 and **no Jenkins API token exists** -- the token in `~/.grafana_token`
is Grafana's, see [#13](#13-grafana-service-account-token). Jenkins was idle, and
came back up in 20 seconds. Note that a deleted job cannot be confirmed over
HTTP without credentials either: Jenkins checks permission before existence, so
the URL returns 403 rather than 404. Disk state and a clean startup log are the
verification.

Config and all 5 build records are backed up at
`~/youless_reader-job-backup.tgz` on patricia (4.7K). Delete that once you are
satisfied the job is gone for good.

## 13. Grafana service-account token

Created 2026-08-24 for the dashboard API work, still active, with the token in
`~/.grafana_token` on patricia. Revoke both if it was only for that.

## 14. Install the current deploy script on patricia and pi4

**Done -- confirmed 2026-08-29.** Split out of
[#1](#1-add-the-freshness-check-to-the-deploy-pipeline), whose note claimed this
was still outstanding on both nodes. Checking rather than trusting the note
showed it had **already been done on both**, so the row was closed the moment it
was opened. The note in #1 was simply stale.

Why it mattered: Jenkins invokes the deploy helper through `sudo` at a **fixed
path** and the sudoers rule pins that path, so editing
`deployment/deploy_youless.sh` in git changes nothing until it is installed on
each node:

```sh
sudo install -m 0700 -o root -g root \
  deployment/deploy_youless.sh /usr/local/sbin/deploy-youless.sh
```

Evidence, both nodes, 2026-08-29 ~20:20 CEST:

| | patricia | pi4 |
|---|---|---|
| `deploy-youless.sh` blob | `d14617b` | `d14617b` |
| `youless-freshness.py` | installed 19:03 | installed 19:16 |
| `youless-freshness.timer` | active | active |
| last run exit status | 0 | 0 |

The installed script hashes are **identical to the repo blob**
(`git hash-object deployment/deploy_youless.sh` -> `d14617b`), so neither node is
running an old copy. The freshness timers fire every 5 minutes and the mutual
cross-check works in both directions -- patricia logged `OK pi4: newest row 12s
old`, pi4 logged `OK patricia: newest row 2s old`. So the monitoring from #1 is
genuinely live, not merely deployed, and `/etc/youless/freshness.env` must exist
on both (the deploy skips enabling the timer without it).

To re-verify later, per node:

```sh
git hash-object deployment/deploy_youless.sh          # repo side
sudo git hash-object /usr/local/sbin/deploy-youless.sh # node side, must match
systemctl list-timers youless-freshness.timer
journalctl -u youless-freshness -n 3 -o cat
```

This does **not** cover a *future* edit to `deploy_youless.sh` -- the same manual
install is needed again each time, and nothing enforces it. A hash comparison in
the smoke-check stage would turn that into a loud failure instead of a silent
no-op.

## 15. Dead man's switch: nothing catches a whole-house outage

Split out of [#2](#2-make-the-freshness-check-actually-reach-someone) on
2026-08-29, which closed the push half.

`OnFailure=` can only fire **from a node that is still alive**. That covers the
daemon crashing, the database refusing connections, capture stalling. It does
not cover a node that lost power or died outright.

One node dying is fine -- the nodes cross-check, so the survivor reports it.
The uncovered case is **both** going at once: power cut, ISP outage, router
failure. Nothing publishes, the phone stays quiet, and quiet reads exactly like
healthy. That is the same shape as the 98-day pi4 outage.

Fixing it needs something **outside the house** that expects a regular ping and
alerts when the pings *stop*. Note the inversion: every other check here alerts
on a bad signal, this one has to alert on the absence of a good one.

There is no VPS to put it on -- `sprenkelshosting.nl` resolves to the home
connection -- so this means a third party. Healthchecks.io free tier is the
obvious candidate: each node pings a URL every 5 minutes, it alerts when a ping
does not arrive. Deferred on 2026-08-29 only because it needs an account first.

Do not put it on patricia. An alerter inside the failure domain cannot report
that domain failing.

## 16. Nothing monitors replica divergence

Moved out of [#2](#2-make-the-freshness-check-actually-reach-someone) on
2026-08-29, where it sat as a sub-note and would have been buried once that item
was ticked.

Both nodes can be **individually fresh while drifting apart**. The freshness
check asks "is each node still writing rows?", which pi4 answered yes to for 15
months while its history diverged, until the 2026-08-24 backfill.

A periodic per-month row-count comparison would catch it -- `data_sync.py
--dry-run` already prints exactly that, so the detection logic exists and only
needs scheduling plus a threshold.

Now cheap to wire up: it can reuse the `OnFailure=` push path from #2 rather
than inventing its own alerting.

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
