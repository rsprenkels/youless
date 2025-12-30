# Project to read time series data from a youless, and visualize with garafana
## Goals
* run a data gathering daemon that stores in SQLite
* do remote development over ssh to pi
* setup Grafana in docker, and attach to SQLite datasource
* have a dashboard app visible remotely on phone

## Remote development

## install youless reader as systemd service

The youless daemon runs as a dedicated user called youless.
https://chatgpt.com/s/t_694b1303856c8191adbfb7783aa5a135


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

```
sqlite> .schema data
sqlite> select datetime(tm, 'unixepoch') as dt from data;
sqlite> select datetime(tm, 'unixepoch') as dt, net, pwr from data;
sqlite> .exit
```

```angular2html
ron@patricia:~/IdeaProjects/youless/data $ sqlite3 youless.data ".schema data"
CREATE TABLE data (
                    tm int,
                    net numeric,
                    pwr int,
                    ts0 int,
                    cs0 numeric,
                    ps0 int,
                    p1 numeric,
                    p2 numeric,
                    n1 numeric,
                    n2 numeric,
                    gas numeric,
                    gts int,
                    wtr numeric,
                    wts int);

```