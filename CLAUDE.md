# CLAUDE.md - AI Assistant Guide for Dirtbikechina

This document provides comprehensive guidance for AI assistants working with the Dirtbikechina codebase.

## Project Overview

**Dirtbikechina.com** is a self-hosted, multi-service online community platform for dirt bike enthusiasts in China. The project integrates multiple open-source applications into a cohesive ecosystem using Docker Compose and Caddy reverse proxy.

**Project Goal**: Build the largest online community for dirt bike lovers based in China

**Current Branch**: `claude/claude-md-mi2ietv71svti2p3-019H9HPL8sKcFn6A8mSYe6Px` (feature branch)

## Architecture & Technology Stack

### Core Services

1. **Discourse** - Main forum/community discussions
   - Custom PostgreSQL image with CJK (Chinese/Japanese/Korean) text search support
   - Custom plugin: `discourse-logto-mobile-session` for SSO integration
   - Additional plugins: `docker_manager`, `discourse-locations`

2. **WordPress** - Long-form article publishing
   - MySQL database backend
   - PHPMyAdmin for database administration
   - Upload limits: 10MB files, 15MB POST

3. **Wanderer** - Trail recording and sharing platform
   - Svelte frontend (port 3000)
   - PocketBase backend (port 8090)
   - Meilisearch for search functionality (port 7700)

4. **Logto** - Centralized authentication/Identity Provider
   - Main service (port 3001)
   - Admin interface (port 3002)
   - PostgreSQL database (shared with Discourse)

5. **Caddy** - Reverse proxy & SSL termination
   - Automatic HTTPS
   - Routes all subdomain traffic

### Database Architecture

- **MySQL** - WordPress database (port 3306)
- **PostgreSQL 15** - Discourse & Logto database (port 5432)
  - Custom build with `pg_cjk_parser` extension
  - `pgvector` extension for AI plugin support
  - Standard extensions: `hstore`, `pg_trgm`

### Network Architecture

```
Internet (80/443)
    ↓
Caddy (Reverse Proxy)
    ├── www.dirtbikechina.com → WordPress
    ├── admin.www.dirtbikechina.com → PHPMyAdmin (basic auth)
    ├── forum.dirtbikechina.com → Discourse (Unix socket)
    ├── trails.dirtbikechina.com → Wanderer Svelte
    ├── admin.trails.dirtbikechina.com → PocketBase
    ├── auth.dirtbikechina.com → Logto
    └── admin.auth.dirtbikechina.com → Logto Admin
```

Docker Networks:
- `caddy_edge` - External network for reverse proxy (must be created manually)
- `wp_net` - WordPress & MySQL
- `wanderer_net` - Wanderer services
- `logto_net` - Logto & PostgreSQL
- `discourse_net` - Discourse & PostgreSQL

## Directory Structure

```
/home/user/dirtbikechina/
├── .git/                       # Git repository
├── .gitignore                  # Git exclusions
├── .gitmodules                 # Submodule config (pg_cjk_parser)
│
├── README.md                   # Main documentation
├── CLAUDE.md                   # This file - AI assistant guide
│
├── guides/                     # Development guides
│   └── plugin.md              # Discourse plugin development
│
├── submodules/                 # Git submodules
│   └── pg_cjk_parser/         # PostgreSQL CJK parser (from huangjimmy/pg_cjk_parser)
│
├── wordpress/                  # WordPress content (gitignored, bind mount)
│   └── .gitkeep
│
├── Docker Compose Files:
│   ├── compose.edge.yml       # Caddy reverse proxy
│   ├── compose.infra.yml      # Databases (MySQL, PostgreSQL)
│   └── compose.apps.yml       # Applications (WordPress, Wanderer, Logto)
│
├── Configuration Files:
│   ├── Caddyfile              # Reverse proxy routing
│   ├── app.sample.yml         # Discourse configuration template
│   ├── sample.env             # Environment variables template
│   ├── .env                   # Actual env vars (gitignored)
│   ├── uploads.ini            # PHP upload limits
│   └── alias.sh               # Bash aliases for Docker ops
│
└── Database & Build Files:
    ├── discourse.Dockerfile    # Custom PostgreSQL with CJK support
    └── discourse_init.sh       # PostgreSQL initialization script
```

## Key Configuration Files

### 1. Docker Compose Files

The project uses a **multi-file compose approach** for modularity:

**compose.edge.yml** (`/home/user/dirtbikechina/compose.edge.yml`)
- Caddy service on ports 80/443
- Connects to all application networks
- Mounts Discourse Unix socket at `/var/discourse/shared/standalone:/sock`
- Requires pre-created `caddy_edge` external network

**compose.infra.yml** (`/home/user/dirtbikechina/compose.infra.yml`)
- MySQL service with health checks
- PostgreSQL 15 custom build with CJK support
- Both databases have proper health check configurations
- Uses YAML anchors for reusable health check definitions

**compose.apps.yml** (`/home/user/dirtbikechina/compose.apps.yml`)
- Uses **profiles** for selective service deployment:
  - `wordpress` - WordPress & PHPMyAdmin
  - `wanderer` - Meilisearch, PocketBase, Svelte
  - `logto` - Logto authentication
  - `init` - Database initialization services
- YAML anchors for shared environment variables

### 2. Environment Configuration

**sample.env** → **.env** (`/home/user/dirtbikechina/sample.env`)

Key variables:
```bash
# Domain
DOMAIN_APEX=dirtbikechina.com

# Caddy
CADDY_PROXY_ADMIN=<username>
CADDY_PROXY_PASSWORD=<bcrypt_hash>  # Use: docker exec caddy caddy hash-password

# MySQL (WordPress)
MYSQL_ROOT_PASSWORD=<password>
MYSQL_DATABASE=<dbname>
MYSQL_USER=<user>
MYSQL_PASSWORD=<password>

# Discourse
DISCOURSE_HOSTNAME=forum.dirtbikechina.com
DISCOURSE_DEVELOPER_EMAILS=<emails>
DISCOURSE_SMTP_*=<smtp_config>
DISCOURSE_DB_*=<db_config>
DISCOURSE_CONNECT_SECRET=<secret>

# Wanderer
MEILI_MASTER_KEY=<key>
POCKETBASE_ENCRYPTION_KEY=<key>

# PostgreSQL (Logto)
POSTGRES_USER=<user>
POSTGRES_PASSWORD=<password>  # No special chars (URL encoding issues)
```

**IMPORTANT**: Always use `sample.env` as a template. Never commit `.env` to git.

### 3. Caddy Configuration

**Caddyfile** (`/home/user/dirtbikechina/Caddyfile`)

Routing rules:
```
dirtbikechina.com → redirect to www.dirtbikechina.com
www.dirtbikechina.com → wordpress:80
admin.www.dirtbikechina.com → phpmyadmin:80 (basic auth)
forum.dirtbikechina.com → unix//sock/nginx.http.sock (Discourse)
trails.dirtbikechina.com → svelte:3000
admin.trails.dirtbikechina.com → pocketbase:8090
auth.dirtbikechina.com → logto:3001
admin.auth.dirtbikechina.com → logto:3002
```

### 4. Discourse Configuration

**app.sample.yml** → **app.yml** (`/home/user/dirtbikechina/app.sample.yml`)

Located at `/var/discourse/containers/app.yml` in production.

Key sections:
- Templates: redis, web, ratelimited, socketed
- Environment variables (use `{{VARIABLE}}` placeholders)
- Docker networks: `dirtbikechina_discourse_net` and `caddy_edge`
- Plugin hooks:
  ```yaml
  hooks:
    after_code:
      - git clone https://github.com/discourse/docker_manager.git
      - git clone https://github.com/merefield/discourse-locations
      - git clone https://{{GITHUB_PAT}}@github.com/monkeyboiii/discourse-logto-mobile-session.git
  ```

**Building Discourse**: `cd /var/discourse && ./launcher rebuild app`

## Database Configuration

### PostgreSQL CJK Support

**Critical for Chinese/Japanese/Korean text search**

**discourse.Dockerfile** (`/home/user/dirtbikechina/discourse.Dockerfile`)
- Multi-stage build
- Compiles `pg_cjk_parser` from source (submodule)
- Installs `pgvector` from PGDG packages
- Based on `postgres:15`

**discourse_init.sh** (`/home/user/dirtbikechina/discourse_init.sh`)

Initialization script that:
1. Creates Discourse database role and database
2. Installs extensions: `hstore`, `pg_trgm`, `vector`, `pg_cjk_parser`
3. Creates custom text search parser `pg_cjk_parser`
4. Creates text search configuration `config_2_gram_cjk`
5. Sets as default for Discourse database
6. Runs smoke tests for Chinese, Japanese, and Korean parsing

**Test Queries**:
```sql
-- Japanese/Chinese test
SELECT to_tsvector('Doraemnon Nobita「ドラえもん のび太の牧場物語」多拉A梦 野比大雄')
  @@ plainto_tsquery('のび太');

-- Korean test
SELECT to_tsvector('大韩민국개인정보의 수집 및 이용 목적')
  @@ plainto_tsquery('大韩민국개인정보');
```

### Database Health Checks

Both databases use health checks with:
- Interval: 5s
- Timeout: 5s
- Retries: 30

```yaml
# PostgreSQL
test: pg_isready -U $POSTGRES_USER -d $POSTGRES_DATABASE

# MySQL
test: mysqladmin ping -h 127.0.0.1 -uroot -p$MYSQL_ROOT_PASSWORD --silent
```

## Development Workflows

### Docker Operations

**Bash Aliases** (`/home/user/dirtbikechina/alias.sh`)

Add to `~/.bashrc`:
```bash
source ~/dirtbikechina/alias.sh
```

Available aliases:
```bash
sdp                    # docker ps
sdpa                   # docker ps -a
sdc                    # docker compose
sdeit                  # docker exec -it
sdcpd                  # docker compose -p dirtbikechina
sdcpdf                 # Full stack: -f compose.edge.yml -f compose.infra.yml -f compose.apps.yml

sdcid <service>        # Get container ID
sdcex <service> [cmd]  # Execute command in service container (default: /bin/bash)
eased <alias>          # Expand alias definition
```

### Starting Services

**Full Stack**:
```bash
# Start all profiles
sdcpdf --profile wordpress --profile wanderer --profile logto up -d

# Or individually
sdcpdf --profile wordpress up -d
sdcpdf --profile wanderer up -d
```

**Infrastructure Only**:
```bash
sdcpd -f compose.infra.yml up -d
```

**Edge Only**:
```bash
sdcpd -f compose.edge.yml up -d
```

### WordPress Database Configuration

After first run:
```bash
# Load environment variables
export $(grep -v '^\s*#' .env | xargs)

# Update WordPress URLs
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "UPDATE wp_options SET option_value = 'https://www.dirtbikechina.com' WHERE option_name IN ('siteurl','home');"

# Confirm
docker exec -it mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
```

### Discourse Development

See **guides/plugin.md** (`/home/user/dirtbikechina/guides/plugin.md`) for detailed setup.

**Development Machine Setup**:
1. Ubuntu server with `calvin` user
2. Docker, PostgreSQL 16, rbenv, nvm, pnpm
3. Redis & Mailhog containers for dev
4. PostgreSQL vector extension from PGDG

**Running Dev Server**:
```bash
export PUBLIC_IP=$(ip -o -4 addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)
DISCOURSE_HOSTNAME=$PUBLIC_IP UNICORN_LISTENER=$PUBLIC_IP:3000 bin/ember-cli -u
```

**Running Plugin Tests**:
```bash
# All plugin tests
RAILS_ENV=test bundle exec rake plugin:spec["discourse-logto-mobile-session"]

# Single test file
bin/rspec ./plugins/discourse-logto-mobile-session/spec/requests/logto_mobile_session_spec.rb

# Single test (line number)
bin/rspec ./plugins/discourse-logto-mobile-session/spec/requests/logto_mobile_session_spec.rb:247
```

### Network Preparation

**Required before first run**:
```bash
sudo docker network create caddy_edge
```

All other networks are created automatically by Docker Compose.

## Custom Extensions & Plugins

### 1. pg_cjk_parser (PostgreSQL Extension)

**Source**: Git submodule from `git@github.com:huangjimmy/pg_cjk_parser.git`

**Purpose**: Enables 2-gram Chinese, Japanese, and Korean text search in PostgreSQL

**Location**: `/home/user/dirtbikechina/submodules/pg_cjk_parser/`

**Integration**:
- Built in `discourse.Dockerfile` multi-stage build
- Installed via `discourse_init.sh`
- Creates custom parser and `config_2_gram_cjk` configuration
- Set as default for Discourse database

**Text Search Configuration Mappings**:
- `asciihword`, `cjk`, `email` → `simple`
- `asciiword` → `english_stem`
- All other types → `simple`

### 2. discourse-logto-mobile-session (Discourse Plugin)

**Source**: Private GitHub repository `monkeyboiii/discourse-logto-mobile-session`

**Purpose**: Coordinates session token issuance between Discourse and Logto IdP

**Installation**: Cloned during Discourse container build via `app.yml` hooks

**Requires**: GitHub Personal Access Token (PAT) in environment as `GITHUB_PAT`

**Development**: See guides/plugin.md for detailed development workflow

### 3. Additional Discourse Plugins

- **docker_manager** - Official Discourse plugin management
- **discourse-locations** - Location/mapping features for posts

## Deployment & Operations

### Prerequisites

1. **Domain**: DNS configured at registrar
2. **Email Server**: SMTP provider for transactional emails (required by Discourse)
3. **Server**: Linux host with Docker installed

### Initial Deployment

1. **Clone repository**:
   ```bash
   git clone <repo-url>
   cd dirtbikechina
   ```

2. **Configure environment**:
   ```bash
   cp sample.env .env
   # Edit .env with your values
   ```

3. **Create external network**:
   ```bash
   sudo docker network create caddy_edge
   ```

4. **Start infrastructure**:
   ```bash
   sdcpd -f compose.infra.yml up -d
   ```

5. **Initialize Discourse database** (if using init service):
   ```bash
   sdcpdf --profile init up discourse-init
   ```

6. **Configure Discourse**:
   ```bash
   # Create app.yml from template
   # Substitute environment variables
   # Place at /var/discourse/containers/app.yml

   cd /var/discourse
   ./launcher rebuild app
   ```

7. **Start applications**:
   ```bash
   sdcpdf --profile wordpress --profile wanderer --profile logto up -d
   ```

8. **Start edge (Caddy)**:
   ```bash
   sdcpd -f compose.edge.yml up -d
   ```

9. **Configure WordPress URLs** (see WordPress Database Configuration above)

### Rebuilding Discourse

When configuration or plugins change:
```bash
cd /var/discourse
./launcher rebuild app
```

This process:
- Downloads latest Discourse updates
- Installs plugins from hooks
- Rebuilds the container
- Typically takes 10-15 minutes

### Monitoring

**View logs**:
```bash
# All services
sdcpdf logs -f

# Specific service
sdcpdf logs -f wordpress
docker logs -f app  # Discourse (managed by launcher)
```

**Service status**:
```bash
sdcpdf ps
docker ps | grep discourse
```

### Backups

**Critical data locations**:
- WordPress: `./wordpress/` (bind mount)
- MySQL: `mysql_data` volume
- PostgreSQL: `postgres_data` volume
- Discourse: `/var/discourse/shared/standalone/`
- Wanderer: `meili_data`, `pocketbase_data`, `svelte_data` volumes

**Backup strategy**:
```bash
# Docker volumes
docker run --rm -v postgres_data:/data -v $(pwd):/backup ubuntu tar czf /backup/postgres_backup.tar.gz -C /data .

# Bind mounts
tar czf wordpress_backup.tar.gz wordpress/
tar czf discourse_backup.tar.gz /var/discourse/shared/
```

## Important Conventions & Best Practices

### 1. Environment Variables

- **Never commit `.env`** - Always use `sample.env` as template
- Use `${VAR:?error}` syntax in compose files to enforce required variables
- PostgreSQL passwords: Avoid special characters (URL encoding issues)
- Caddy password: Generate with `docker exec -it caddy caddy hash-password --plaintext "password"`

### 2. Docker Compose

- **Use project name**: `-p dirtbikechina` for consistency
- **Multi-file approach**: `-f compose.edge.yml -f compose.infra.yml -f compose.apps.yml`
- **Profiles**: Use `--profile <name>` for selective deployment
- **Health checks**: Always wait for `service_healthy` in `depends_on`
- **Networks**: Separate concerns (edge, wp_net, wanderer_net, logto_net, discourse_net)

### 3. Discourse

- **Configuration**: Use `app.yml` templates, never edit running containers
- **Plugins**: Add via hooks in `app.yml`, rebuild container after changes
- **Database**: Separate PostgreSQL instance, shared with Logto
- **Networking**: Must connect to both `discourse_net` and `caddy_edge`
- **Socket**: Nginx socket at `/var/discourse/shared/standalone/` mounted to Caddy

### 4. Database Operations

- **PostgreSQL**: Always test CJK parsing after initialization
- **MySQL**: Update WordPress URLs after first run
- **Migrations**: Database initialization scripts are idempotent
- **Extensions**: Required for Discourse: `hstore`, `pg_trgm`, `vector`, `pg_cjk_parser`

### 5. Security

- **Basic auth**: PHPMyAdmin protected with Caddy basic auth
- **Passwords**: Use strong passwords, bcrypt for Caddy
- **Private repos**: Use PAT tokens in `app.yml` for private plugins
- **File permissions**: Consider restricting `app.yml` to root only

### 6. Git Workflow

- **Submodules**: `pg_cjk_parser` is a git submodule, update with `git submodule update --init`
- **Gitignore**: `.env`, `app.yml`, `wordpress/` (except `.gitkeep`)
- **Branches**: Feature branches use `claude/` prefix
- **Commits**: Clear, descriptive messages (see recent history)

### 7. File References

When referencing code in discussions, use the pattern `file_path:line_number`:

Examples:
- Caddy routing: `Caddyfile:25` (Discourse forum route)
- Database init: `discourse_init.sh:46` (CJK parser creation)
- Compose profiles: `compose.apps.yml:38` (WordPress profile)

### 8. CJK Language Support

- **Critical feature**: Chinese/Japanese/Korean text search is core to the platform
- **Custom parser**: `pg_cjk_parser` is custom-built, not in standard PostgreSQL
- **Testing**: Always run smoke tests after database initialization
- **Configuration**: `config_2_gram_cjk` must be set as default for Discourse database

## Testing & Validation

### Database Initialization Tests

The `discourse_init.sh` script includes automated tests:

1. **Extension installation verification**
2. **CJK parser creation check**
3. **Chinese/Japanese parsing test**: `のび太` (Nobita) and `野比大雄` (Nobi Daiyuu)
4. **Korean parsing test**: `大韩민국개인정보` (Korean privacy info)

All tests must pass (return `t`) for initialization to succeed.

### Manual Testing

**WordPress**:
- Access `https://www.dirtbikechina.com`
- Verify database connection
- Check upload functionality (10MB limit)

**Discourse**:
- Access `https://forum.dirtbikechina.com`
- Test CJK search functionality
- Verify plugin functionality
- Check SSO integration with Logto

**Wanderer**:
- Access `https://trails.dirtbikechina.com`
- Test trail upload/search
- Verify Meilisearch integration

**Logto**:
- Access `https://auth.dirtbikechina.com`
- Test authentication flow
- Verify Discourse integration

## Troubleshooting

### Common Issues

**1. Caddy can't access Discourse socket**
- Check socket mount: `/var/discourse/shared/standalone:/sock`
- Verify Discourse is using socketed template
- Check file permissions on socket

**2. PostgreSQL extension not found**
- Ensure custom image is built: `docker images | grep postgres`
- Check submodule is initialized: `git submodule update --init`
- Rebuild image if needed

**3. WordPress URLs incorrect**
- Run URL update script (see WordPress Database Configuration)
- Check `WP_HOME` and `WP_SITEURL` environment variables

**4. Service dependency failures**
- Check health check status: `docker inspect <container> | grep Health`
- Increase health check retries if needed
- Verify database credentials

**5. Network connectivity issues**
- Confirm `caddy_edge` network exists: `docker network ls`
- Verify services are on correct networks: `docker inspect <container>`
- Check Caddyfile routing configuration

**6. Plugin installation failures**
- Verify `GITHUB_PAT` is set for private repos
- Check internet connectivity from container
- Review Discourse logs: `cd /var/discourse && ./launcher logs app`

### Useful Commands

```bash
# Check all container health
docker ps --format "table {{.Names}}\t{{.Status}}"

# Inspect network connections
docker network inspect caddy_edge

# View environment variables
docker inspect <container> | grep -A 20 Env

# Database connection test
docker exec -it postgres psql -U $POSTGRES_USER -d discourse -c "SELECT version();"

# Rebuild specific service
sdcpdf up -d --force-recreate --build <service>

# Clean restart
sdcpdf down
docker volume prune  # WARNING: Removes all unused volumes
sdcpdf up -d
```

## Additional Resources

### Documentation
- Main README: `/home/user/dirtbikechina/README.md`
- Plugin Development: `/home/user/dirtbikechina/guides/plugin.md`
- Blog post: https://calvin.dirtbikechina.com/blog/self-host-dirtbikechina-with-docker

### External Documentation
- Discourse Installation: https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md
- Discourse Development: https://meta.discourse.org/t/install-discourse-on-ubuntu-or-debian-for-development/14727
- Caddy Documentation: https://caddyserver.com/docs/
- Docker Compose: https://docs.docker.com/compose/

### Key Files Quick Reference

| File | Purpose | Location |
|------|---------|----------|
| compose.edge.yml | Caddy reverse proxy | `/home/user/dirtbikechina/compose.edge.yml` |
| compose.infra.yml | Database services | `/home/user/dirtbikechina/compose.infra.yml` |
| compose.apps.yml | Application services | `/home/user/dirtbikechina/compose.apps.yml` |
| Caddyfile | Routing configuration | `/home/user/dirtbikechina/Caddyfile` |
| .env | Environment variables | `/home/user/dirtbikechina/.env` (gitignored) |
| sample.env | Environment template | `/home/user/dirtbikechina/sample.env` |
| app.yml | Discourse config | `/var/discourse/containers/app.yml` |
| app.sample.yml | Discourse template | `/home/user/dirtbikechina/app.sample.yml` |
| discourse_init.sh | DB initialization | `/home/user/dirtbikechina/discourse_init.sh` |
| discourse.Dockerfile | Custom PostgreSQL | `/home/user/dirtbikechina/discourse.Dockerfile` |
| alias.sh | Docker aliases | `/home/user/dirtbikechina/alias.sh` |
| uploads.ini | PHP upload limits | `/home/user/dirtbikechina/uploads.ini` |

## Version Information

- **PostgreSQL**: 15
- **MySQL**: latest
- **WordPress**: latest
- **Caddy**: latest
- **Meilisearch**: v1.16.0
- **Wanderer**: flomp/wanderer-db (latest)
- **Logto**: latest

## Git Repository Info

**Current Status**: Clean working tree
**Active Branch**: `claude/claude-md-mi2ietv71svti2p3-019H9HPL8sKcFn6A8mSYe6Px`

**Recent Commits**:
```
6fe037f - pluign tutorial documented
be854c9 - added my plugin
ec42d3a - remove unnecessary basic auth
eccf505 - discourse bootstrapped successfully
904b073 - standalone postgres container, proper init
```

**Submodules**:
- `submodules/pg_cjk_parser` → `git@github.com:huangjimmy/pg_cjk_parser.git`

---

**Document Version**: 1.0
**Last Updated**: 2025-11-17
**Maintainer**: AI Assistant (Claude)
