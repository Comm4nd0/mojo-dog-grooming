#!/bin/bash
# Deploy the Mojo and Co backend on the Hetzner host.
# Usage: ./deploy.sh [--skip-pull] [--no-cache] [--yes]
#
# --yes answers the low-memory prompt for you. CI passes it; see
# .github/workflows/deploy.yml.

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
    if [[ "$*" == *"--yes"* ]]; then
        echo "         --yes was given, continuing."
    elif [ -t 0 ]; then
        read -r -p "Continue anyway? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || exit 1
    else
        # Refuse rather than read. Piped in over SSH — which is how CI runs
        # this — stdin is the remote script itself, so `read` would silently
        # swallow the next line of the deploy and carry on with a mangled one.
        echo "ERROR: nothing to ask on (stdin is not a terminal)."
        echo "       Pass --yes to deploy anyway."
        exit 1
    fi
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
# No `down` first. `up -d` recreates only the containers whose image or config
# actually changed, which for a code push means `web` alone: Postgres keeps
# running, so the deploy costs one container restart instead of taking the whole
# stack down and waiting for the database's health check to pass again on the way
# back up. That mattered less when deploying was occasional and deliberate; it
# happens on every push to main now.
#
# --remove-orphans does the one useful thing `down` did that `up` won't: clear
# out a container for a service that has since been renamed or deleted from the
# compose file. For a genuine full stop — restoring a backup, say — run
# `docker compose -f docker-compose.prod.yml down` by hand first and then this.
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

echo ""
echo ">>> Waiting for the health check..."
for i in $(seq 1 30); do
    # Both headers matter, and for different reasons.
    #
    # Host: hitting the bridge IP directly sends "Host: 172.17.0.1:8010",
    # which is not in DJANGO_ALLOWED_HOSTS, so Django answers 400
    # DisallowedHost and this check could never pass: every deploy burned the
    # full five minutes and then reported failure over a container that was up
    # and serving the whole time.
    #
    # X-Forwarded-Proto: DJANGO_SECURE_HTTPS turns on SECURE_SSL_REDIRECT, so
    # plain HTTP gets a 301 to https://localhost/ — and curl -f does not fail
    # on a 3xx. Without this the check passed on the redirect alone, which
    # proves only that something is listening. Claiming the app is up is worth
    # something now that nobody is watching the deploy: we want the actual
    # {"status": "ok"} body, so a container that boots and then 500s on every
    # request is caught here rather than left serving.
    if curl -fsS -H 'Host: localhost' -H 'X-Forwarded-Proto: https' \
            http://172.17.0.1:8010/api/health/ 2>/dev/null \
            | grep -q '"status": *"ok"'; then
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
