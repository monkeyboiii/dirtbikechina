# Plugin

I have built a custom [plugin](https://github.com/monkeyboiii/discourse-logto-mobile-session) for Discourse that coordinates session token issurance with Logto as IdP. This page documents the dev work environment preparation to start fiddling. In addtion to the offical [tutorial](https://meta.discourse.org/t/install-discourse-on-ubuntu-or-debian-for-development/14727), I documented some quirks.

## Machine

1. Provision a machine (ubuntu, preferably), then as *root*, run

```shell
useradd -m -s /bin/bash calvin
groupadd wheel

passwd calvin

usermod -aG root calvin

# add the below line to sudoer
# %wheel         ALL = (ALL) NOPASSWD: ALL
visudo

# switch to user folder
ssh-keygen -t ed25519
```

2. Copy `.ssh/authorized_keys`.

> Can use ProxyJump in .ssh/config with vscode remote ssh plugin, to curb the GFW.

## Softwares

1. Docker, from [apt](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository), then use `compose.yml`
  * Redis
  * Mailhog
2. PostgreSQL (host, 16)
  * postgresql-16-pgvector, see below
3. rbenv
  * `rbenv install -L`, list remote
4. nvm
  * `nvm install --lts`
5. pnpm

### PostgreSQL Vector Extension

Required by Discourse AI plugin.

```shell
sudo install -d -m 0755 /usr/share/keyrings

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg

echo 'deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt noble-pgdg main' \
  | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

sudo apt update
```

### docker-compose.yml

So you can `sudo docker compose up -d`, and `sudo docker compose down`.

```yaml
services:
  redis:
    image: redis
    ports:
      - "127.0.0.1:6379:6379"
    restart: unless-stopped
  mail:
    image: mailhog/mailhog
    ports:
      - "127.0.0.1:1025:1025"
      - "127.0.0.1:8025:8025"
    restart: unless-stopped
```

## Development Environment

1. bundle install
2. pnpm install
3. db create and migrate as specified [here](https://meta.discourse.org/t/install-discourse-on-ubuntu-or-debian-for-development/14727).

## Start

```shell
# applicable to rented instances
export PUBLIC_IP=$(ip -o -4 addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)

DISCOURSE_HOSTNAME=$PUBLIC_IP UNICORN_LISTENER=$PUBLIC_IP:3000 bin/ember-cli -u
```

## Unit Tests
```shell
# my plugin namme
RAILS_ENV=test bundle exec rake plugin:spec["discourse-logto-mobile-session"]

# single file, single test
bin/rspec ./plugins/discourse-logto-mobile-session/spec/requests/logto_mobile_session_spec.rb:247
```