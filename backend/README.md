# Planner Sync Backend

Single-user sync server for PlannerApp.

## Deploy on VPS

```bash
scp -r backend root@91.108.189.121:/opt/planner-sync
ssh root@91.108.189.121
cd /opt/planner-sync
cp .env.example .env
openssl rand -hex 32
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
