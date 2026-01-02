# Project to read time series data from a youless, and visualize with garafana
## Goals
* run a data gathering daemon that stores in SQLite
* do remote development over ssh to pi
* setup Grafana in docker, and attach to SQLite datasource
* have a dashboard app visible remotely on phone

## Remote development

## install youless reader as systemd service

The youless daemon runs as a dedicated user called youless.

## Deploying with Jenkins


### run a Jenkins agent on the target machine

read https://chatgpt.com/s/t_69584986d5c48191978cfd8d452d0e65

user jenkins on the agent needs to be allowed to check out the git repo:
* create a user `jenkins` on the agent:
```aiignore
sudo useradd \
  --system \
  --user-group \
  --create-home \
  --home-dir /var/lib/jenkins \
  --shell /usr/bin/bash \
  jenkins
```
Also create the location for the agent to check out stuff:
````aiignore
sudo -u jenkins mkdir -p /var/lib/jenkins/agent
sudo -u jenkins chmod 700 /var/lib/jenkins/agent

````

Install java:
````aiignore
sudo apt update && sudo apt install -y openjdk-17-jre-headless 
````

In the Jenkins controller container:
```aiignore
docker exec -it <jenkins_container_name> bash -lc '
mkdir -p /var/jenkins_home/.ssh
chmod 700 /var/jenkins_home/.ssh
ssh-keyscan -H 192.168.2.25 >> /var/jenkins_home/.ssh/known_hosts
chmod 600 /var/jenkins_home/.ssh/known_hosts
'

```

* Generate a key pair, and add the public key of jenkins@agent as deployment key to the git repo on github; and
* Add the host key of github.com to the known_hosts file of jenkins@agent:
```
ssh-keygen -t ed25519 -C "jenkins@<agent_name>"

cd .ssh/
ssh -o StrictHostKeyChecking=yes -T git@github.com
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
```
## Postgress TimescaleDB
```aiignore
services:
  timescaledb:
    image: timescale/timescaledb:latest-pg16
    container_name: timescaledb
    restart: unless-stopped
    environment:
      POSTGRES_DB: timescale
      POSTGRES_USER: tsdb
      POSTGRES_PASSWORD: <<secret>>
    ports:
      - "5432:5432"
    volumes:
      - /opt/timescaledb/data:/var/lib/postgresql/data
```



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

TODO: some more lines

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
