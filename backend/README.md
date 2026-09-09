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

## One-time BMSTU schedule import

The schedule importer downloads the BMSTU ICS feed, converts each class into a
`calendarEvent`, and writes it through the same transactional SQLite change log
used by app synchronization. It does not create tasks, kanban cards, or widget
entries. Re-running it is safe: imported records have stable IDs and are
recognized as already applied.

After deploying an image built from this revision, run on the VPS:

```bash
install -o root -g root -m 0750 backend/scripts/import-bmstu-schedule.sh /opt/planner-sync/import-bmstu-schedule.sh
/opt/planner-sync/import-bmstu-schedule.sh
```

The default source is the supplied ИУ1-72Б feed. To import another compatible
ICS URL, set `BMSTU_ICS_URL` for the command. Classes are stored in
`Europe/Moscow`, with no local notification and no project assignment.

## Telegram quick capture

The same process can accept private Telegram messages, transcribe short voice
notes, parse a small deterministic Russian date/time grammar, and append tasks
through the v2 change log. No Redis, ffmpeg, or separate worker service is
required. Telegram support is off by default.

Required values when `PLANNER_TELEGRAM_ENABLED=true`:

- `TELEGRAM_BOT_TOKEN` from BotFather;
- `TELEGRAM_WEBHOOK_SECRET`, 16–256 letters, digits, underscores, or hyphens;
- `TELEGRAM_ALLOWED_USER_ID`, the numeric ID of the only permitted user;
- `GROQ_API_KEY`; `GROQ_STT_MODEL` defaults to `whisper-large-v3`;
- `PLANNER_TIMEZONE`, which defaults to `Europe/Moscow`.

Voice messages are limited to 30 seconds and 1 MiB. They are downloaded as OGG
and sent directly to Groq. Enable Zero Data Retention for the Groq project. To
use the optional Yandex SpeechKit fallback, set `STT_FALLBACK=yandex` together
with `YANDEX_API_KEY` and `YANDEX_FOLDER_ID`; otherwise leave it as `none`.

Before registering the webhook, send a message to the bot and call `getUpdates`
to read the numeric `message.from.id`. Then register only message updates. With
the self-signed certificate from the deployment example, upload the public
certificate in the same request:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
curl -F "url=https://91.108.189.121/telegram/webhook" \
  -F "secret_token=${TELEGRAM_WEBHOOK_SECRET}" \
  -F 'allowed_updates=["message"]' \
  -F "certificate=@certs/planner.crt" \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook"
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
```

Supported examples include `купить молоко сегодня в 18:00`, `позвонить врачу
завтра в пятнадцать`, and `сдать отчёт до завтра`. Relative dates are calculated
from the original Telegram message time. Ambiguous or unsupported expressions
are rejected with an example instead of silently creating a wrongly dated task.

The `telegram_updates` SQLite queue deduplicates by bot and update ID and resumes
expired work after a restart. Task text and voice file identifiers are removed
from terminal queue rows. The existing app sync protocol is unchanged.

### Telegram notifications

When Telegram support is enabled, the backend also sends proactive messages to
the private chat identified by `TELEGRAM_ALLOWED_USER_ID`:

- a daily summary at 07:00 in `PLANNER_TIMEZONE`; it mirrors the app's Today
  view, including active overdue tasks and tasks whose scheduled time or due
  date is no later than the end of today;
- a reminder 15 minutes before an active task's `scheduled` time. Due dates do
  not produce a Telegram reminder.

The schedule and lead time are fixed server policies. They are independent of
the Apple app's local notification setting. Delivery state is kept in SQLite,
so retries and process restarts do not normally duplicate notifications. Events
whose trigger passed while the backend was stopped are deliberately not sent
later. A task created or rescheduled after its reminder trigger is also not
backfilled.

## One-time transition from v1

1. Stop every old client so it cannot write through the v1 protocol.
2. Stop the backend and archive the old SQLite database together with WAL/SHM.
3. Remove the active old database, deploy backend v2, and verify `/v2/sync/status` reports an empty server.
4. On the device that contains the authoritative data, choose **Initialize empty server** in sync settings.
5. Reconnect the other devices and replace their old local sync state with the data pulled from the server.

Do not initialize from two devices. If the server is no longer empty, the
initialize endpoint rejects the request and normal incremental sync must be
used.
