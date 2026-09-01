# Planner Sync Backend v2

Single-user sync server for PlannerApp.

The v2 protocol is revision based. Clients pull the change log, persist changes,
push an idempotent outbox, and pull once more. The server never accepts a
destructive bootstrap over an existing database.

## Deploy on VPS

```bash
scp -r backend root@91.108.189.121:/opt/planner-sync
ssh root@91.108.189.121
cd /opt/planner-sync
cp .env.example .env
# Generate two different secrets:
openssl rand -hex 32 # PLANNER_SYNC_TOKEN
openssl rand -hex 32 # PLANNER_WIDGET_TOKEN
nano .env
mkdir -p certs
openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
  -keyout certs/planner.key \
  -out certs/planner.crt \
  -subj "/CN=91.108.189.121" \
  -addext "subjectAltName=IP:91.108.189.121"
openssl x509 -in certs/planner.crt -noout -fingerprint -sha256
docker compose up -d --build
curl -k https://91.108.189.121/health
```

Put the SHA256 fingerprint, server URL, and token into PlannerApp Settings.

## API v2

- `GET /v2/sync/status` reports the protocol version, server revision, and whether the server is empty.
- `POST /v2/sync/initialize` accepts the first snapshot only while the server is empty.
- `GET /v2/sync/changes?after=<revision>&limit=<page-size>` returns a page from the monotonic change log.
- `POST /v2/sync/mutations` applies idempotent UUID mutations using each entity's `baseRevision`.
- `GET /v2/widget/snapshot` returns a minimal read-only projection of active tasks and projects for the iOS widget.

Sync endpoints accept only `PLANNER_SYNC_TOKEN`. The widget endpoint accepts
only the separate `PLANNER_WIDGET_TOKEN`; this token cannot initialize, mutate,
delete, or read the full sync change log. Production clients only connect over
HTTPS and should pin the server certificate fingerprint.

## Database migrations and backup

SQLite migrations are numbered and applied one transaction at a time. Before
changing a non-empty database, the server checkpoints WAL and creates a backup
in `migration-backups`. Startup refuses to open a database whose schema version
is newer than the binary supports.

Keep the database volume and `migration-backups` in regular infrastructure
backups as well; the automatic copy only protects the migration boundary.

## One-time transition from v1

1. Stop every old client so it cannot write through the v1 protocol.
2. Stop the backend and archive the old SQLite database together with WAL/SHM.
3. Remove the active old database, deploy backend v2, and verify `/v2/sync/status` reports an empty server.
4. On the device that contains the authoritative data, choose **Initialize empty server** in sync settings.
5. Reconnect the other devices and replace their old local sync state with the data pulled from the server.

Do not initialize from two devices. If the server is no longer empty, the
initialize endpoint rejects the request and normal incremental sync must be
used.
