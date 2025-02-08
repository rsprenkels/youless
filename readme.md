# install as systemd service

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