# Production VPS deployment templates

These files are versioned deployment templates. They do not change the VPS by
themselves and deliberately do not replace `backend/docker-compose.yml`.

The production container is pulled from GHCR using an immutable 40-character
commit SHA. Runtime secrets stay in `/opt/planner-sync/.env`, TLS files stay in
`/opt/planner-sync/certs`, and the SQLite named volume is selected during the
one-time bootstrap. Telegram and STT values are therefore never present in a
GitHub Actions log.

## One-time root bootstrap

Run these commands on the VPS as root after taking a backup of the existing
deployment. Replace `EXISTING_VOLUME` with the output of `docker volume ls`
for the current `planner-sync-data` volume; do not create a new volume when the
old database must be retained.

```sh
install -d -o root -g root -m 0750 /opt/planner-sync /var/lib/planner-sync
install -o root -g root -m 0750 infra/deploy/compose.production.yml /opt/planner-sync/compose.production.yml
install -o root -g root -m 0750 infra/deploy/deploy-planner-sync /usr/local/sbin/deploy-planner-sync
install -d -o root -g root -m 0700 /opt/planner-sync/certs
chmod 0600 /opt/planner-sync/.env
printf '%s\n' 'PLANNER_DATA_VOLUME=EXISTING_VOLUME' >> /opt/planner-sync/.env
```

The `.env` file must already contain the existing sync/widget tokens and TLS
paths. The compose template uses the same defaults as the backend and keeps
the named volume external so an accidental project-name change cannot create
a second database. Confirm the chosen volume before the first `up`:

```sh
docker volume inspect EXISTING_VOLUME
docker login ghcr.io                 # store read-only GHCR credentials in root's Docker config
```

The GHCR credential needs only `read:packages` and must not be copied into the
repository or passed through GitHub Actions.

## Restricted GitHub Actions SSH key

Create a dedicated Unix account (no sudo and no membership in the `docker`
group), then install the public key in its `authorized_keys` with a forced
command. The forced command receives the original command through
`SSH_ORIGINAL_COMMAND`; the script accepts only a single 40-hex SHA.

```sh
useradd --system --create-home --home-dir /home/planner-deploy --shell /bin/sh planner-deploy
install -d -o planner-deploy -g planner-deploy -m 0700 /home/planner-deploy/.ssh
install -o planner-deploy -g planner-deploy -m 0600 /tmp/github-actions.pub /home/planner-deploy/.ssh/authorized_keys
```

Prefix the key line in `authorized_keys` as follows (keep the public key after
the final space). `sudo` is included because the deploy script itself must run
as root to access Docker and the root-only secrets:

```text
command="sudo -n /usr/local/sbin/deploy-planner-sync",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... github-actions-planner-sync
```

Because the forced command is root-owned and the account cannot run Docker
directly, grant exactly this command through `/etc/sudoers.d/planner-deploy`:

```sudoers
planner-deploy ALL=(root) NOPASSWD: /usr/local/sbin/deploy-planner-sync
```

Preserve the SSH command for the root script when sudo applies its environment
sanitization:

```sudoers
Defaults:planner-deploy env_keep += "SSH_ORIGINAL_COMMAND"
```

Validate the sudo rule with `visudo -cf /etc/sudoers.d/planner-deploy` and test
with a disposable SHA. Do not grant `docker` group access: it is equivalent to
root on the host.

## GitHub Actions environment

Create a protected GitHub Environment named `production` and add these
secrets, without printing them in workflow steps:

* `VPS_HOST`
* `VPS_USER` (`planner-deploy`)
* `VPS_SSH_PRIVATE_KEY` (the private key whose public half is restricted above)
* `VPS_KNOWN_HOSTS` (the exact output of `ssh-keyscan -H VPS_HOST` obtained
  from a trusted network)

The workflow should connect with `ssh "$VPS_USER@$VPS_HOST" deploy-planner-sync
"$GITHUB_SHA"`; the immutable SHA is the only deployment input.

## Manual verification and rollback

The deploy script pulls the requested image, starts it, and polls the effective
planner listener. If `HEALTH_URL` is explicitly set in the root environment it
uses that URL; otherwise it reads `PLANNER_ADDR` from the running
`planner-sync` container and polls `https://127.0.0.1:<port>/health` (default
port `443`). On a failed health check it starts the previously
recorded tag from `/var/lib/planner-sync/active-tag` and verifies health again.
The SQLite volume is never removed. A first deployment must have a valid
previous tag recorded (or be performed manually by root) before rollback is
available.

### Updating an existing deployment that uses `PLANNER_ADDR=:8443`

The initial production deployment may already be running on port `8443`, while
older copies of the script still probe the default port `443`. Update only the
root-owned script on the VPS, keeping the existing `.env`, certificates, and
SQLite volume unchanged:

```sh
install -o root -g root -m 0750 infra/deploy/deploy-planner-sync /usr/local/sbin/deploy-planner-sync
grep '^PLANNER_ADDR=' /opt/planner-sync/.env
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' planner-sync | grep '^PLANNER_ADDR='
```

Both checks should show `PLANNER_ADDR=:8443`. Do not change it to `:443` just
for the health check. After installing the updated script, re-run the failed
`Deploy immutable image to VPS` GitHub Actions job. The script will discover
port `8443` from the running container, verify
`https://127.0.0.1:8443/health`, and record the deployed SHA. A manual check is:

```sh
curl --fail --silent --show-error --insecure https://127.0.0.1:8443/health
```
