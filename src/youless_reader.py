#!/usr/bin/python
import json
import time

import requests

import youless_dao_postgres


def youless_reader():
    dao = youless_dao_postgres.Dao()
    prev_datagram = None
    while True:
        r = requests.get("http://192.168.2.12/e")
        if r.status_code == 200:
            datagram = json.loads(r.content)[0]
            if prev_datagram is None or datagram["tm"] != prev_datagram["tm"]:
                prev_datagram = datagram
                dao.add(datagram)
                print(datagram)
            time.sleep(5)


if __name__ == "__main__":
    youless_reader()
