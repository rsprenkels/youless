#!/usr/bin/python
import json
import logging as log
import os
import time
import requests
from datetime import datetime, timezone

loglevel = os.getenv("LOG_LEVEL", "INFO").upper()

log.basicConfig(
    level=getattr(log, loglevel, log.INFO),
    format="%(asctime)s %(levelname)-5s %(name)s %(message)s",
)


def youless_reader():
    write_to_dao = os.getenv("WRITE_TO_DAO", "True").upper() in ("TRUE", "1", "YES")
    log.error(
        f"starting youless_reader, write_to_dao:{write_to_dao} loglevel:{loglevel}"
    )

    if write_to_dao:
        import youless_dao_postgres

        dao = youless_dao_postgres.Dao("data")
    prev_datagram = None
    while True:
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
            time.sleep(5)


if __name__ == "__main__":
    youless_reader()
