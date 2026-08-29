# Installing youless on a fresh node

A "node" is one machine that independently polls the YouLess meter and stores
every sample in its own local TimescaleDB. Nodes do not depend on each other:
if one is down or mid-deploy, the others keep capturing. Today there are two,
`patricia` and `pi4`.

This document lists only what must be done **by hand**. Everything else is
handled by git + Jenkins -- see [What the deploy does for you](#what-the-deploy-does-for-you)
so you do not repeat it manually.

Verified against the live nodes on 2026-08-25.

---

## 0. Before you start

- A Debian-family Linux box (both current nodes are Raspberry Pi OS, arm64).
- **Network access to the meter.** The address is currently hardcoded:
  `http://192.168.2.12/e` in `src/youless_reader.py`. A node on a different
  network needs that changed -- it is not configuration yet.
- Docker, for the database.
- The node must be reachable over SSH from the Jenkins controller host.

Pick a **node letter** now (`A` = patricia, `B` = pi4, so a third node is `C`).
It becomes the `uid` prefix in the database and identifies which node a row
physically lives on.

## 1. Database

TimescaleDB in Docker. On the node:

```yaml
# /opt/timescaledb/docker-compose.yml
services:
  timescaledb:
    image: timescale/timescaledb:latest-pg16
    container_name: timescaledb
    restart: unless-stopped
    environment:
      POSTGRES_DB: timescale
      POSTGRES_USER: tsdb
      POSTGRES_PASSWORD: <<secret>>
    ports:
      - "5432:5432"
    volumes:
      - /opt/timescaledb/data:/var/lib/postgresql/data
```

```sh
cd /opt/timescaledb && docker compose up -d
```

Then create the schema, passing your node letter:

```sh
psql -h localhost -U tsdb -d timescale -v prefix=C -f deployment/schema.sql
```

`deployment/schema.sql` is idempotent and creates the table, the hypertable
(30-day chunks), the `tm` index, the `id` sequence, the per-node generated `uid`
column, and the compression policy. **Do not hand-write this schema** -- the old
`CREATE TABLE` inside the DAO had drifted badly and would produce a plain table
that can never carry a continuous aggregate.

Verify:

```sh
psql -h localhost -U tsdb -d timescale -c \
  "SELECT hypertable_name, num_chunks, compression_enabled
   FROM timescaledb_information.hypertables;"
```

## 2. Secrets: `/etc/youless/youless.env`

The reader gets its DSN from here. Not in git, and never will be.

```sh
sudo install -d -m 0755 /etc/youless
sudo tee /etc/youless/youless.env >/dev/null <<'EOF'
PG_DSN="host=localhost port=5432 dbname=timescale user=tsdb password=<<secret>>"
EOF
sudo chmod 0600 /etc/youless/youless.env
```

Two things worth knowing:

- **You do not need to create a `youless` user.** The service runs as
  `User=daemon`, a stock account. A `youless` user exists on the current nodes
  and owns this file, but nothing runs as it -- ownership is cosmetic, because
  systemd reads `EnvironmentFile` **as root before dropping privileges**. Mode
  `0600 root:root` is fine.
- The unit uses `EnvironmentFile=-/etc/youless/youless.env`. The leading `-`
  means *ignore if missing*, so a missing file does **not** fail the unit --
  the reader starts, finds no `PG_DSN`, and dies with a `ValueError` instead.
  If startup fails with that, this file is the first thing to check.

## 3. Secrets: `/etc/youless/freshness.env`

Config for the capture-freshness check. Node-specific: `NODES` lists **this
node and its peers**, so each node watches itself and the others.

```sh
sudo tee /etc/youless/freshness.env >/dev/null <<'EOF'
PGUSER=tsdb
PGPASSWORD=<<secret>>
PGDATABASE=timescale
NODES="localhost patricia pi4"
MAX_LAG_SECONDS=300
EOF
sudo chmod 0640 /etc/youless/freshness.env
```

The deploy installs the check and its units, but **only enables the timer once
this file exists** -- it will not enable a unit that could only fail. If you
skip this step the deploy prints a warning and the node has no capture
monitoring.

Peer hostnames must resolve from this node. `patricia` and `pi4` resolve for
each other via `.home` on the LAN.

## 3b. Secrets: `/etc/youless/notify.env`

Where failure notifications go. Read by `youless-notify@.service`, which
`OnFailure=` starts when the freshness check fails.

```sh
sudo tee /etc/youless/notify.env >/dev/null <<'EOF'
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=<<the shared topic>>
EOF
sudo chmod 0600 /etc/youless/notify.env
```

**Use the same topic on every node**, so one subscription on the phone covers
the whole fleet.

The topic name is the **only** secret on the public ntfy.sh instance: anyone who
knows it can read the alerts and publish fakes. So it is a long random string,
it is `0600 root:root`, and it stays out of git. Alert text is deliberately
generic (`youless: <unit> failed on <host>` plus journal lines), so a leaked
topic exposes nothing beyond the fact that a home energy meter exists.

Unlike the freshness timer there is nothing to enable -- `OnFailure=` starts the
template unit on demand. The deploy therefore installs the notifier
unconditionally and only *warns* when this file is missing. Note what that
means: **a node with no `notify.env` still runs its freshness check and still
enters failed state, it just cannot tell anyone.**

To subscribe: install the **ntfy** app, Subscribe to topic, enter the topic name,
leave the server as `ntfy.sh`.

Verify the whole path end to end with a unit that fails on purpose:

```sh
sudo tee /etc/systemd/system/notify-selftest.service >/dev/null <<'EOF'
[Unit]
OnFailure=youless-notify@%N.service
[Service]
Type=oneshot
ExecStart=/bin/false
EOF
sudo systemctl daemon-reload
sudo systemctl start notify-selftest.service          # expected to fail
journalctl -u youless-notify@notify-selftest -n 5 -o cat
sudo rm /etc/systemd/system/notify-selftest.service && sudo systemctl daemon-reload
```

Testing by hand with `systemctl start youless-notify@foo` would only prove the
script and network work. This proves the `OnFailure=` wiring, which is the part
that actually has to fire at 03:00.

## 4. The privileged deploy helper

Jenkins invokes this through `sudo` at a **fixed path**, so it must be copied
into place by hand -- and re-copied whenever it changes in git.

```sh
sudo install -m 0700 -o root -g root \
  deployment/deploy_youless.sh /usr/local/sbin/deploy-youless.sh
```

> **This is the step people forget.** Editing `deployment/deploy_youless.sh` in
> git changes nothing on the node until you re-run the line above. The sudoers
> rule pins `/usr/local/sbin/deploy-youless.sh`, so it cannot be run from the
> Jenkins workspace.

## 5. Jenkins agent and sudoers

Create the `jenkins` user and its agent workspace:

```sh
sudo useradd --system --user-group --create-home \
  --home-dir /var/lib/jenkins --shell /usr/bin/bash jenkins
sudo -u jenkins mkdir -p /var/lib/jenkins/agent
sudo -u jenkins chmod 700 /var/lib/jenkins/agent
sudo apt update && sudo apt install -y openjdk-17-jre-headless
```

Grant exactly the rights the pipeline needs, no more:

```sh
sudo EDITOR=vi visudo -f /etc/sudoers.d/jenkins-youless
```

```
# Allow jenkins to run the youless deploy script without a password
jenkins ALL=(root) NOPASSWD: /usr/local/sbin/deploy-youless.sh

# Allow jenkins to check service status (the smoke-check stage)
jenkins ALL=(root) NOPASSWD: /bin/systemctl is-active youless.service
jenkins ALL=(root) NOPASSWD: /bin/systemctl status youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl is-active youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl status youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl --no-pager --full status youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl is-active --quiet youless.service

# Allow jenkins to hash the installed deploy helper, so the smoke-check stage
# can prove it matches the repo. The helper is mode 0700 root:root and cannot
# be read otherwise. Read-only, and pinned to this one file.
jenkins ALL=(root) NOPASSWD: /usr/bin/sha256sum /usr/local/sbin/deploy-youless.sh
```

```sh
sudo chmod 0440 /etc/sudoers.d/jenkins-youless
sudo -u jenkins sudo -n /usr/local/sbin/deploy-youless.sh --help          # verify
sudo -u jenkins sudo -n /usr/bin/sha256sum /usr/local/sbin/deploy-youless.sh
```

> **Without that last rule the smoke-check stage fails** with
> `sudo: a password is required`. The rule is deliberately narrow: `sha256sum`
> is read-only and the path is pinned, so it grants no ability to modify
> anything. Note that pinning the path is what makes it safe -- a bare
> `NOPASSWD: /usr/bin/sha256sum` would let the `jenkins` user read the first
> bytes of *any* file on the system, including `/etc/shadow`.

Give `jenkins` a deploy key for the repo:

```sh
sudo -u jenkins ssh-keygen -t ed25519 -C "jenkins@<node>"
sudo -u jenkins ssh-keyscan -t ed25519 github.com >> /var/lib/jenkins/.ssh/known_hosts
```

Add the public key to the GitHub repo's deploy keys.

On the Jenkins controller, add the node as an agent and give it a **label**.
Then add that label to the `DEPLOY_TARGET` choices in the `Jenkinsfile` --
they are hardcoded (`['pi', 'patricia']`), so a new node needs a commit:

```groovy
choice(name: 'DEPLOY_TARGET', choices: ['pi', 'patricia', '<new-label>'], ...)
```

Also add the node's host key on the controller:

```sh
docker exec -it <jenkins_container> bash -lc '
  mkdir -p /var/jenkins_home/.ssh && chmod 700 /var/jenkins_home/.ssh
  ssh-keyscan -H <node-ip> >> /var/jenkins_home/.ssh/known_hosts
  chmod 600 /var/jenkins_home/.ssh/known_hosts'
```

## 6. First deploy

Run `youless_pipeline` with `DEPLOY_TARGET` set to the new node's label.
Everything from here is automatic.

## 7. Verify

```sh
# reader is up and pinging its watchdog
systemctl is-active youless.service
systemctl show youless.service -p NRestarts -p WatchdogTimestamp

# it is actually storing samples -- lag should be under ~15s
psql -h localhost -U tsdb -d timescale -c \
  "SELECT count(*), max(tm), now()-max(tm) AS lag FROM data;"

# monitoring is live
systemctl list-timers youless-freshness.timer
sudo systemctl start youless-freshness.service
journalctl -u youless-freshness.service -n 5 --no-pager   # expect OK lines

# nothing failed
systemctl --failed
```

Watch a restart end to end:

```sh
journalctl -u youless.service -f -o short-precise --since now
# elsewhere: sudo systemctl restart youless.service
```

Expect `Received signal 2`, one final `datagram:`, then
`exit requested, exiting now` -- the graceful shutdown that captures a last
sample before exiting.

## 8. Backfill history (optional)

A new node starts empty. To copy an existing node's history:

```sh
PG_DSN_FROM="host=patricia port=5432 dbname=timescale user=tsdb password=<<secret>>" \
PG_DSN_TO="host=localhost port=5432 dbname=timescale user=tsdb password=<<secret>>" \
python3 src/tools/data_sync.py --dry-run
```

Drop `--dry-run` to run it. It compares per-month row counts and copies only
what is missing, via `COPY` into a staging table plus one anti-join insert.
Roughly 6.5 minutes for 2.65M rows. `id` and `uid` are deliberately not copied
-- each node generates its own.

---

## What the deploy does for you

Do **not** do these by hand; `deploy-youless.sh` handles them on every run:

| | |
|---|---|
| `/opt/youless/src/*.py` | reader and DAO |
| `/opt/youless/.venv` | rebuilt whenever `pyvenv.cfg` is missing, then `pip install -r requirements.txt` **into it**. Built from `--python`, default `/usr/bin/python3`. Preserved across deploys, along with `data/` |
| `/etc/systemd/system/youless.service` | the unit, including `WatchdogSec=60` |
| `/usr/local/sbin/youless-freshness.py` | the freshness check |
| `youless-freshness.{service,timer}` | its units, timer enabled when `freshness.env` exists |
| `youless-notify.sh` + `youless-notify@.service` | the push path; nothing to enable, `OnFailure=` starts it |
| `systemctl daemon-reload` + restart | |

## Gotchas

- **`deploy_youless.sh` changes need a manual copy** to
  `/usr/local/sbin/deploy-youless.sh`. See step 4. Since 2026-08-29 the
  smoke-check stage sha256s both copies and **fails the build** when they
  differ, so this can no longer pass unnoticed. That check needs the
  `sha256sum` sudoers rule in step 5.
- **Notifications only fire from a node that is still alive.** `OnFailure=`
  cannot report a node that lost power or died outright. The two nodes
  cross-check, so one dying is covered by the other -- but **both** going down
  (power cut, ISP outage) is silent. Closing that needs a dead man's switch
  outside the house.
- **The meter IP is hardcoded** in `src/youless_reader.py`.
- **The unit and the reader must deploy together.** `WatchdogSec=60` kills a
  reader that does not send `WATCHDOG=1`; older code does not. The deploy
  installs both in one pass, so the normal path is safe -- only hand-editing
  the unit is dangerous.
- **Never overwrite `/etc/youless/freshness.env` from a deploy.** It holds a
  password and differs per node.
- **A node with no `freshness.env` has no monitoring** and will not tell you so
  beyond one warning line in the deploy log.
- **`.venv` must contain `pyvenv.cfg`, and nothing else counts.** Both nodes ran
  for months on a `.venv` that was only three symlinks and no `pyvenv.cfg`. An
  interpreter in such a directory is not in a venv at all -- `sys.prefix ==
  sys.base_prefix` -- so `pip install` silently wrote into the *system*
  interpreter, and the reader imported `psycopg2` from `/usr/local` while
  appearing to run from a venv. Two old bugs in the deploy caused it and both are
  fixed as of 2026-08-29: `find -type f -delete` gutted the venv without removing
  its symlinks, and the rebuild guard tested `-x bin/python`, which a surviving
  symlink satisfies. To check a node:
  ```bash
  /opt/youless/.venv/bin/python -c 'import sys; print(sys.prefix != sys.base_prefix)'
  ```
  It must print `True`. If it prints `False`, delete `.venv` and redeploy.
