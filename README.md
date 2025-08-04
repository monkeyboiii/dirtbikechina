# Dirt Bike China

**dirtbikechina.com™** is a project that aims to build the **largest** online community for dirt bike lovers based in China.

## Tech Stacks

Using OSS applications including

1. [Discourse](https://www.discourse.org/) for the main online forum.
2. [Wanderer](https://wanderer.to/) for trail recording and sharing support.
3. [WordPress](https://wordpress.org/) for long-form articles.
4. [Caddy](https://caddyserver.com/) for reverse proxy, SSL termination, etc.
5. [Docker](https://www.docker.com/) to nicely wrap it all up.

we can self-host the project on a single Linux server.

## Prerequisites

The high level workflow is described below. For a more detailed blog post, please visit [here](https://calvin.dirtbikechina.com/blog/self-host-dirtbikechina-with-docker).

1. Domain:
    - You need to configure DNS resolution settings from your registrar in later steps.
2. Email server:
    - We need an email service provider capable of transactional emails, which is essential to *Discourse*.
3. Hosting server:
    - With docker installed.

## Docker Preparation

1. Create a bridge network:
    - `sudo docker network create caddy_net`.

## WordPress Installation

Bundled in the `compose.yml` file.

After the container is running in Docker, update the `site_url` and `home` entry in DB using

```shell
export $(grep -v '^\s*#' .env | xargs)

# update
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "UPDATE wp_options SET option_value = 'https://www.dirtbikechina.com' WHERE option_name IN ('siteurl','home');"

# confirm
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
```

## Discourse Installation

1. Follow step 6 in discourse [installation guide](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md#6-install-discourse).
2. Create a symbolic link from this repo to that location, i.e. `ln -s /var/discourse discourse`, for convenience.
3. Copy the `app.yml` file under `discourse/containers/`, or better, hard link to that location and `chown`.
    - Optionally, revoke RW access other than `root` for `app.yml`.
4. Substitute necessary environment variables to `app.yml`.
5. Run the following command to build the containers.

```shell
# under /var/discourse, as root
./launcher rebuild app
```

## Wanderer Installation

Bundled in the `compose.yml` file. Set appropriate keys beforehand.

## Caddy Configuration

Refer to `Caddyfile`.
