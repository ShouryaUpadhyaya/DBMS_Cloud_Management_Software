# Deploying CRMS on a shared VPS

These are **instructions for a human**. Nothing in this repository connects to a server. The stack is designed to sit
beside services that already run on the machine: it publishes only two loopback ports, has no database port, uses
`crms_`-prefixed names, and caps memory.

## What gets installed

| Container | Role | Exposed | Memory |
|---|---|---|---|
| `db` | PostgreSQL 16 + pg_cron, pgcrypto, btree_gist, pg_stat_statements | **nothing** (internal network only) | 768 MB |
| `api` | Express API | `127.0.0.1:${API_PORT:-14000}` | 256 MB |
| `web` | nginx serving the React build, proxying `/api` to the API | `127.0.0.1:${WEB_PORT:-18088}` | 64 MB |
| `collector` | docker-mode metrics + logs collector | nothing | 128 MB |
| `docker-proxy` | read-only Docker API (`POST=0`), the only container that sees `docker.sock` | nothing | 32 MB |

Total ≈ 1.25 GB RAM ceiling, ~1 GB disk to start (metrics grow ~1M rows per resource-month at 1/min; retention
drops old partitions). Named volume: `crms_pgdata`. Network: `crms_internal`. Compose project name: `crms`.

## 0. Before you start

```bash
ss -ltn | grep -E ':(14000|18088)\b'      # both must be free (or choose other ports in .env)
docker ps --format '{{.Names}}'           # make sure no existing container is named crms-*
docker volume ls | grep crms_             # expect nothing
free -m                                   # ~1.3 GB available
```

## 1. Get the code and secrets

```bash
git clone <your repo url> /opt/crms && cd /opt/crms
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
# fill in real values:
openssl rand -hex 24      # use for POSTGRES_PASSWORD, CRMS_APP_PASSWORD, CRMS_COLLECTOR_PASSWORD, CRMS_READONLY_PASSWORD
openssl rand -hex 32      # use for JWT_SECRET
```

All compose commands below use a shorthand:

```bash
alias crms='docker compose --env-file deploy/.env -f deploy/docker-compose.vps.yml'
```

## 2. Build and start

```bash
crms up -d --build
crms ps                    # db becomes "healthy"; api/web/collector start
```

## 3. Create the schema and the first administrator

```bash
# apply migrations 001..012 (idempotent: already-applied files are skipped)
set -a; . deploy/.env; set +a
crms exec -T db env CRMS_APP_PASSWORD="$CRMS_APP_PASSWORD" \
  CRMS_COLLECTOR_PASSWORD="$CRMS_COLLECTOR_PASSWORD" \
  CRMS_READONLY_PASSWORD="$CRMS_READONLY_PASSWORD" bash /db/migrate.sh

# roles, permission catalogue, pricing, one admin, and the default "Unassigned" project.
# Do NOT run the demo seed on a real server: it creates users with a known password.
crms exec -T db psql -U postgres -d crms -v ON_ERROR_STOP=1 \
  -v admin_email=you@example.com -v admin_password='choose a long passphrase' \
  -f /deploy/bootstrap.sql
```

Within about a minute the collector (docker mode) lists the host's containers, networks and volumes. They appear in
the **Unassigned** project. Create projects, then move ownership by labelling containers with
`crms.project=<Project name>` (picked up on the next tick for *new* resources).

Check:

```bash
curl -s http://127.0.0.1:18088/api/health               # {"status":"ok","db":true}
crms logs collector --tail 5                             # "ingested {...new_resources...}"
```

## 4. Reverse proxy

Terminate TLS on the host. The web container already proxies `/api`, so the outer proxy needs one upstream.

### nginx (add as a new `server` block; leave your existing ones untouched)

```nginx
server {
    listen 443 ssl http2;
    server_name crms.example.com;
    ssl_certificate     /etc/letsencrypt/live/crms.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/crms.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:18088;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
    }
    # Server-Sent Events (live alerts) must not be buffered
    location /api/stream {
        proxy_pass http://127.0.0.1:18088;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

Then `sudo nginx -t && sudo systemctl reload nginx`; obtain the certificate with `certbot --nginx -d crms.example.com`.

### Caddy

```caddy
crms.example.com {
    reverse_proxy 127.0.0.1:18088 {
        flush_interval -1
    }
}
```

## 5. Operations

**Backups** (daily cron on the host):

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.vps.yml exec -T db \
  pg_dump -U postgres -Fc crms > /var/backups/crms-$(date +%F).dump
# restore into an empty database:  pg_restore -U postgres -d crms --clean --if-exists < file.dump
```

**Update**

```bash
git pull
crms up -d --build
crms exec -T db env CRMS_APP_PASSWORD="$CRMS_APP_PASSWORD" CRMS_COLLECTOR_PASSWORD="$CRMS_COLLECTOR_PASSWORD" \
  CRMS_READONLY_PASSWORD="$CRMS_READONLY_PASSWORD" bash /db/migrate.sh
```

**Rotate a database password**: `crms exec -T db psql -U postgres -d crms -c "ALTER ROLE crms_app PASSWORD '…'"`, then
update `deploy/.env` and `crms up -d api`.

**Retention** runs nightly via pg_cron (`sp_rollup_and_retention(30)`: daily rollups first, then old partitions are
dropped) and the materialized view refreshes hourly. Check: `SELECT jobname, schedule, active FROM cron.job;`.

**Resource use**: `docker stats --no-stream $(docker ps --filter name=crms- -q)`.

**Stop / remove** (does not touch other services):

```bash
crms down            # stop, keep data
crms down -v         # stop and DELETE the crms_pgdata volume
```

## 6. Security checklist

- [ ] `deploy/.env` is `chmod 600` and not committed (it is in `.gitignore`).
- [ ] `ss -ltn` shows `14000`/`18088` bound to `127.0.0.1` only, and **no** PostgreSQL port from this stack.
- [ ] `docker-proxy` is the only container with `/var/run/docker.sock`, mounted `:ro`, with `POST=0`.
      Verify: `crms exec docker-proxy wget -qO- --post-data= http://localhost:2375/containers/create` is refused (403).
- [ ] The demo seed was **not** loaded (`SELECT count(*) FROM users WHERE email LIKE '%@crms.test'` is `0`).
- [ ] HTTPS in front; HSTS if the domain is dedicated to this app.
- [ ] Firewall allows only 80/443 (plus SSH) from outside.
- [ ] A backup was taken and a restore was tested once.

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `crms up` fails with "set POSTGRES_PASSWORD" | a required variable is empty in `deploy/.env` |
| Collector log: `password authentication failed for user "crms_collector"` | migrations not applied yet, or `CRMS_COLLECTOR_PASSWORD` differs from the value used when running `migrate.sh` |
| Collector log: `docker /info -> 403` | proxy started without `INFO=1` (it is set in the compose file) |
| Login works but lists are empty | the user has no project membership: add one on the Access page as an admin |
| Port already in use | change `API_PORT` / `WEB_PORT` in `deploy/.env` and re-run `crms up -d` |
