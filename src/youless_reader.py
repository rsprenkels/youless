#!/usr/bin/python
import json
import logging as log
import time
import requests
from datetime import datetime, timezone

log.basicConfig(format="%(asctime)s - %(message)s", level=log.INFO)


def youless_reader():
    write_to_dao = True
    if write_to_dao:
        import youless_dao_postgres

        dao = youless_dao_postgres.Dao("data_test")
    prev_datagram = None
    while True:
        r = requests.get("http://192.168.2.12/e")
        if r.status_code == 200:
            datagram = json.loads(r.content)[0]
            if prev_datagram is None or datagram["tm"] != prev_datagram["tm"]:
                prev_datagram = datagram
                if write_to_dao:
                    dao.add(datagram)
                keys_to_keep = ["tm", "net", "pwr", "p1", "p2", "n1", "n2", "gas"]
                d = {k: datagram[k] for k in keys_to_keep if k in datagram}
                d["tm"] = datetime.fromtimestamp(d["tm"], tz=timezone.utc).strftime(
                    "%Y-%m-%d %H:%M:%S"
                )
                log.info(f"datagram: {d}")
            time.sleep(5)


if __name__ == "__main__":
    youless_reader()
