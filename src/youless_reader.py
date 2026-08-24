#!/usr/bin/python
import json
import logging as log
import os
import signal
import socket
import threading
import time
import requests
from datetime import datetime, timezone

loglevel = os.getenv("LOG_LEVEL", "INFO").upper()

log.basicConfig(
    level=getattr(log, loglevel, log.INFO),
    format="%(asctime)s %(levelname)-5s %(name)s %(message)s",
)

shutdown_event = threading.Event()

# --- systemd watchdog -------------------------------------------------------
# Implemented against $NOTIFY_SOCKET directly rather than pulling in
# systemd-python, to keep requirements.txt at two entries.
_NOTIFY_ADDR = os.getenv("NOTIFY_SOCKET")
_notify_sock = None


def _sd_notify(state: str) -> None:
    """Send a datagram to systemd. No-op when not running under systemd.

    Never raises: a monitoring failure must not be able to stop data capture.
    """
    global _notify_sock
    if not _NOTIFY_ADDR:
        return
    try:
        if _notify_sock is None:
            _notify_sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        addr = _NOTIFY_ADDR
        if addr.startswith("@"):  # abstract namespace socket
            addr = "\0" + addr[1:]
        _notify_sock.sendto(state.encode(), addr)
    except Exception as e:  # pragma: no cover
        log.debug("sd_notify(%s) failed: %s", state, e)


def _request_shutdown(signum, frame):
    log.warning("Received signal %s; requesting shutdown", signum)
    shutdown_event.set()


def youless_reader():
    write_to_dao = os.getenv("WRITE_TO_DAO", "True").upper() in ("TRUE", "1", "YES")
    log.info(
        f"starting youless_reader, write_to_dao:{write_to_dao} loglevel:{loglevel}"
    )

    # Handle the typical stop signals used by systemd/services.
    signal.signal(signal.SIGTERM, _request_shutdown)
    signal.signal(signal.SIGINT, _request_shutdown)

    # Seed the duplicate check from what is already stored. Starting at None
    # means the first sample after any restart gets written unconditionally,
    # even when the previous process already stored that exact tm -- which is
    # where the 28 duplicate timestamps between 2025-08 and 2026-01 came from
    # (Jenkins deploys restart the service, and a restart lands inside a 10s
    # sample window often enough).
    prev_tm = None
    if write_to_dao:
        import youless_dao_postgres

        dao = youless_dao_postgres.Dao("data")
        latest = dao.latest_tm()
        if latest is not None:
            prev_tm = int(latest.timestamp())
            log.info("resuming after last stored sample at %s", latest)

    _sd_notify("READY=1")

    while True:
        # Ping once per iteration, not once per successful read. A meter that
        # is genuinely down should NOT cause a restart loop -- restarting would
        # not fix it, and the freshness check covers that case. What this
        # catches is the loop not turning at all.
        _sd_notify("WATCHDOG=1")
        try:
            # (connect, read) timeouts. Without these the call blocks forever
            # if the meter accepts the connection and then stops replying --
            # no FIN, no RST, so the kernel waits indefinitely. That is exactly
            # how capture on pi4 died silently on 2026-05-18 and stayed dead
            # for 98 days: the process sat in recvfrom() while systemd still
            # reported the unit as "active (running)", so Restart=always never
            # fired. The meter normally answers in ~10ms.
            r = requests.get("http://192.168.2.12/e", timeout=(3.05, 5))
            if r.status_code == 200:
                datagram = json.loads(r.content)[0]
                if prev_tm is None or datagram["tm"] != prev_tm:
                    prev_tm = datagram["tm"]
                    keys_to_keep = ["tm", "net", "pwr", "p1", "p2", "n1", "n2", "gas"]
                    d = {k: datagram[k] for k in keys_to_keep if k in datagram}
                    if write_to_dao:
                        dao.add(d)
                    d["tm"] = datetime.fromtimestamp(d["tm"], tz=timezone.utc).strftime(
                        "%Y-%m-%d %H:%M:%S"
                    )
                    log.info(f"datagram: {d}")
                    # if it was a new datagram, sleep for a little less than 10 seconds -> get in sync with update moment
                    if shutdown_event.is_set():
                        log.info("exit requested, exiting now")
                        exit(0)
                    else:
                        log.debug("taking a long nap")
                        time.sleep(9.5)
                else:
                    # if its the same, sleep very briefly. We want to know asap if there is new data
                    time.sleep(0.3)
                    log.debug("just a quick nap")
            else:
                log.error(f"Error fetching data: {r.status_code}")
                time.sleep(1)
        except Exception as e:
            log.error(f"Exception occurred: {e}", exc_info=True)
            time.sleep(1)


if __name__ == "__main__":
    youless_reader()
