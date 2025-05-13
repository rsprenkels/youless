# Project to read time series data from a youless, and visualize with garafana
## Goals
* run a data gathering daemon that stores in SQLite
* do remote development over ssh to pi
* setup Grafana in docker, and attach to SQLite datasource
* have a dashboard app visible remotely on phone

## Remote development


## install youless reader as systemd service

/etc/systemd/system/youless-reader.service
```
[Unit]
Description=Youless reader service

[Service]
Type=exec
ExecStart=/opt/youless/src/youless_reader.py
WorkingDirectory=/opt/youless/src

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable youless-reader.service
sudo systemctl start youless-reader.service
sudo systemctl status youless-reader.service
```

ron@pi4:/opt/youless/src $ sqlite3  data.sqlite

sqlite> .schema data
sqlite> select datetime(tm, 'unixepoch') as dt from data;
sqlite> .exit

