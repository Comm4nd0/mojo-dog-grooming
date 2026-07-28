#!/bin/bash
# Deploy the Mojo and Co backend on the Hetzner host.
# Usage: ./deploy.sh [--skip-pull] [--no-cache]

set -e

COMPOSE_FILE="docker-compose.prod.yml"

echo "=================================================="
echo "  Deploying Mojo and Co"
echo "=================================================="

if [ ! -f .env ]; then
    echo "ERROR: no .env file. Copy .env.example and fill in the secrets."
    exit 1
fi

# This host runs on a tight memory budget. Bail out early rather than
# OOM-killing another project's container mid-build.
AVAILABLE_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [ "$AVAILABLE_MB" -lt 500 ]; then
    echo "WARNING: only ${AVAILABLE_MB}MB available. The build may fail or"
    echo "         disturb other projects on this host."
    read -r -p "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

if [[ "$*" != *"--skip-pull"* ]]; then
    echo ""
    echo ">>> Pulling latest code..."
    git pull origin main
fi

echo ""
echo ">>> Building..."
if [[ "$*" == *"--no-cache"* ]]; then
    docker compose -f "$COMPOSE_FILE" build --no-cache
else
    docker compose -f "$COMPOSE_FILE" build
fi

echo ""
echo ">>> Restarting containers..."
docker compose -f "$COMPOSE_FILE" down
docker compose -f "$COMPOSE_FILE" up -d

echo ""
echo ">>> Waiting for the health check..."
for i in $(seq 1 30); do
    # -H Host matters. Hitting the bridge IP directly sends "Host:
    # 172.17.0.1:8010", which is not in DJANGO_ALLOWED_HOSTS, so Django
    # answers 400 DisallowedHost and this check could never pass: every
    # deploy burned the full five minutes and then reported failure over a
    # container that was up and serving the whole time.
    if curl -fsS -H 'Host: localhost' http://172.17.0.1:8010/api/health/ >/dev/null 2>&1; then
        echo "    Healthy after ${i}0s."
        break
    fi
    sleep 10
    if [ "$i" -eq 30 ]; then
        echo "    Still unhealthy after 5 minutes. Recent logs:"
        docker compose -f "$COMPOSE_FILE" logs --tail=50 web
        exit 1
    fi
done

echo ""
echo ">>> Status"
docker compose -f "$COMPOSE_FILE" ps
free -m | head -2

echo ""
echo "Done. Remember Caddy needs an app.mojoandco.uk block pointing at"
echo "172.17.0.1:8010 — see Caddyfile in this repo."
