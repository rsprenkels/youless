#!/usr/bin/python
import json
import logging as log
import os
import signal
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


def _request_shutdown(signum, frame):
    log.warning("Received signal %s; requesting shutdown", signum)
    shutdown_event.set()


def youless_reader():
    write_to_dao = os.getenv("WRITE_TO_DAO", "True").upper() in ("TRUE", "1", "YES")
    log.error(
        f"starting youless_reader, write_to_dao:{write_to_dao} loglevel:{loglevel}"
    )

    # Handle the typical stop signals used by systemd/services.
    signal.signal(signal.SIGTERM, _request_shutdown)
    signal.signal(signal.SIGINT, _request_shutdown)

    if write_to_dao:
        import youless_dao_postgres

        dao = youless_dao_postgres.Dao("data")
    prev_datagram = None

    while True:
        try:
            r = requests.get("http://192.168.2.12/e")
            if r.status_code == 200:
                datagram = json.loads(r.content)[0]
                if prev_datagram is None or datagram["tm"] != prev_datagram["tm"]:
                    prev_datagram = datagram
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
