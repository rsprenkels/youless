# TODO

## Add the freshness check to the deploy pipeline

`deployment/youless-freshness.py`, `systemd/youless-freshness.service` and
`systemd/youless-freshness.timer` are currently **hand-installed** on patricia
and pi4 (2026-08-24). `deployment/deploy_youless.sh` does not know about them,
so a rebuilt or newly added node silently comes up with no capture monitoring
at all -- which is exactly the blind spot that let pi4 sit dead for 98 days.

What the deploy script needs to do, alongside the files it already installs:

```sh
install -m 0755 -D "${SRC_DIR}/deployment/youless-freshness.py" /usr/local/sbin/youless-freshness.py
install -m 0644    "${SRC_DIR}/systemd/youless-freshness.service" /etc/systemd/system/
install -m 0644    "${SRC_DIR}/systemd/youless-freshness.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now youless-freshness.timer
```

### Gotchas

- **`/etc/youless/freshness.env` holds the database password** and must stay out
  of the repo. The deploy must not overwrite it -- create it only when absent,
  or leave it entirely to manual provisioning like `/etc/youless/youless.env`.
- **The env file is node-specific.** Each node checks itself *and its peer*:
  patricia has `NODES="localhost pi4"`, pi4 has `NODES="localhost patricia"`.
  So it cannot be one shared template; either derive `NODES` at install time
  from the local hostname, or keep provisioning it by hand.
- `enable --now` is only needed on first install, but it is idempotent, so it is
  safe to run every deploy.
- The script's `find "${APP_DIR}" -mindepth 1 -type f -delete` only clears
  `/opt/youless`. It does not touch `/usr/local/sbin` or `/etc/systemd/system`,
  so no extra cleanup is required.
- The existing sudoers rule grants the whole `deploy-youless.sh`, so adding
  these installs needs no sudoers change. `systemctl enable` on a new unit does
  not need one either, since the script already runs as root.

### Why it matters

The watchdog in `youless.service` catches the reader's loop stalling. It cannot
catch the loop running fine while data fails to land (database unreachable,
disk full, daemon killed and not restarted, host down). Only the freshness
check covers those, and right now it survives only as long as nobody rebuilds a
node.

## Reuse the database connection in the DAO

`Dao.add()` in `src/youless_dao_postgres.py` calls `psycopg2.connect()` for
every single row -- a fresh TCP connection, authentication handshake and
teardown once per 10-second sample, forever. `youless_reader.py` has the same
pattern on the HTTP side: no `requests.Session`, so each poll opens a new
connection to the meter, and it polls every 0.3s while waiting for the next
sample.

Neither is a throughput problem at one row per 10 seconds, but both are pure
overhead, and the database one costs the Pi real CPU for nothing.

Not done yet because it is not a drop-in change: a long-lived connection needs
reconnect-on-failure handling, or the daemon will wedge the first time the
database restarts or the network blips. Get that wrong and it becomes another
silent-stall failure mode, which is exactly what the watchdog was added to
catch. Worth doing carefully, with the watchdog already in place as a backstop.

## Make the freshness check actually reach someone

`youless-freshness.service` writes `CRITICAL ...` to the local journal and exits
non-zero, so the failure shows in `systemctl --failed` and
`journalctl -u youless-freshness`. Both are **pull** signals: they only help if
somebody looks.

The pi4 outage went unnoticed for 98 days precisely because nothing pushed.
Add an `OnFailure=` unit that sends somewhere that reaches a phone -- ntfy,
Pushover, email, a Telegram bot -- so a stopped capture interrupts rather than
waits to be discovered.

Note the two nodes cross-check each other (patricia watches pi4 and vice versa),
so whichever node is still alive can raise the alarm about the other. A single
central alerting path is therefore fine; it does not need to be per-node.

### Related, not yet covered

Nothing monitors **replica divergence**. Both nodes can be individually fresh
while drifting apart -- one missing rows the other has, as pi4 did for 15 months
before the 2026-08-24 backfill. A periodic per-month row-count comparison
(what `data_sync.py --dry-run` already prints) would catch that.
