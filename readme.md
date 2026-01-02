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

## Deploying with Jenkins

user jenkins on the agent needs to be allowed to check out the git repo:
* add the public key of jenkins@agent (or maybe jenkins@container) as deployment key to the git repo on github; and
* add the host key of github.com to the known_hosts file of jenkins@agent:
  +    36  cd .ssh/
       39  ssh -o StrictHostKeyChecking=yes -T git@github.com
       40  ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
       41  chmod 600 ~/.ssh/known_hosts
  +  This is not 100% correct yet. Fiddeling with what runs in the container, versus what runs on the agent.

## create a python venv
This is handled by the jenkinsfile, also the installation of requirements.txt packages.

## deploy_youless.sh helper script
give user `jenkins` specific sudo rights:
```aiignore
sudo visudo -f /etc/sudoers.d/jenkins-youless
```
put the below content into that sudoers file:
```aiignore
# Allow jenkins user to run the youless deploy script without password
jenkins ALL=(root) NOPASSWD: /usr/local/sbin/deploy-youless.sh

# Allow jenkins to check service status (for the smoke check stage)
jenkins ALL=(root) NOPASSWD: /bin/systemctl is-active youless.service
jenkins ALL=(root) NOPASSWD: /bin/systemctl status youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl is-active youless.service
jenkins ALL=(root) NOPASSWD: /usr/bin/systemctl status youless.service
```
Set the correct permissions for the sudoers file:
```aiignore
sudo chmod 0440 /etc/sudoers.d/jenkins-youless
```
Verify:
```aiignore
sudo -u jenkins sudo -n /usr/local/sbin/deploy-youless.sh --help
```

## the daeomn runs as user youless (a non-root, non-sudo, no-login user)

If you need to become user youless, for checking stuff:
```
sudo su -s /bin/bash youless
```
If you need to check the log output of a running daemon:
```
journalctl -u youless.service -n 100 -f

```
