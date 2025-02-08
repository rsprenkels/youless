ron@pi4:~ $ sudo cat /etc/systemd/system/youless-reader.service
[Unit]
Description=Youless reader service

[Service]
Type=exec
ExecStart=/opt/youless/src/youless_reader.py
WorkingDirectory=/opt/youless/src

[Install]
WantedBy=multi-user.target

