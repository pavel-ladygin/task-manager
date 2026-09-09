#!/usr/bin/env sh
set -eu

# Run this on the VPS from /opt/planner-sync after deploying the image that
# contains /app/import-bmstu-schedule. The command uses the existing Docker
# volume and updates the sync change log transactionally.
exec docker compose -f /opt/planner-sync/compose.production.yml run --rm \
  --entrypoint /app/import-bmstu-schedule planner-sync
