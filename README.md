# Dirt Bike China

This project aims to build the largest online community for dirt bike lovers based in China.

## Tech Stacks

Using OSS applications including

1. [WordPress](https://wordpress.org/) for landing page/magazine.
2. [Discourse](https://www.discourse.org/) for online forum.
3. [Caddy](https://caddyserver.com/) for reverse proxy, SSL termination, etc.
4. [Docker](https://www.docker.com/) to nicely wrap it all up.

we can self-host the project on a single linux server.

## Prerequisite

The high level workflow is described below. For a more detailed blog post, please visit [here]().

### Domain

Buy a domain from registrar. You need to configure DNS resolution settings from your registrar in later steps.

> Domains cannot be transferred to a new registrar in 60 days of purchase, according to [ICANN](https://www.icann.org/resources/pages/name-holder-faqs-2017-10-10-en).

### Email Server

We need an email service provider capable of transactional emails, because simple mail service providers like Gmail, Yahoo don't apply. The basic workflow with each provider rougly looks like

1. Add domain to your provider.
2. Verify the domain.
    - The provider will generate DKIM and DMARC TXT and MX records.
    - Fill them into your domain registrar.
    - Verify on the provider website.
3. Generate SMTP information.
4. After the website (WordPress in this case) is online and compliant, request a manual review for approval for account.

Here are a couple to choose from.

#### [Brevo](https://www.brevo.com/) (Recommended by Discourse)

Supports Email templates, has transactional SMS, free for small usage.

1. Strict on compliance.

#### AWS [SES](https://aws.amazon.com/ses/)

Powerful, cheap, good quality of service.

Note that:

1. When copying MX record for `email` prefix, strip the priority value from the given value, refer to [here](https://community.cloudflare.com/t/error-9009-while-entering-mx-record-for-aws-ses/196063/2).
2. Before manual appproval, account is in sandbox mode and cannot sent emails other than verified emails or domains.

### Server

1. Rent a EC2 instance.
2. Install docker following the official [guide](https://docs.docker.com/engine/install/ubuntu/).

## Docker Preparation

1. Create bridge network `sudo docker network create caddy_net`.

## WordPress Install

Bundled in the `docker-compose.yml` file.

After the container is running in docker, update the site_url and home entry in DB using

```shell
export $(grep -v '^\s*#' .env | xargs)

# update
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "UPDATE wp_options SET option_value = 'https://www.dirtbikechina.com' WHERE option_name IN ('siteurl','home');"

# confirm
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
```

## Discourse Install

1. Follow step 6 in discourse [installation guide](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md#6-install-discourse).
2. Create a symbolic link from this repo to that location, i.e. `ln -s /var/discourse discourse`, for convenience.
3. Copy the `app.yml` file under `discourse/containers/`.
4. Optionally, change owership and revoke RW access other than root.
5. Run a series of command to build the containers.

```shell
cd /var/discourse

set -o allexport
source .env
set +o allexport

./launcher rebuild app
```

## Caddy Configuration

Refer to `Caddyfile`.
