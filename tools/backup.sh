#!/bin/bash
# Back up the Mojo and Co production data on the Hetzner host.
#
# Usage: ./tools/backup.sh [--label <text>]
#
# Run from the project directory (/root/mojo-dog-grooming). Called by
# .github/workflows/deploy.yml before every deploy, and intended to be called
# by a nightly cron as well — see "Scheduling" below.
#
# Three artefacts per run, all stamped with the same UTC timestamp:
#
#   db-<stamp>.sql.gz       the database
#   files-<stamp>.tar.gz    private-media/ and media/
#   env-<stamp>             the .env
#
# Why all three, when this used to dump the database alone:
#
# * **private-media/** is the scanned paperwork — signed intake forms carrying
#   name, address, postcode, phone, emergency contact, vet and signature. It is
#   the least replaceable data in the system and it was not backed up at all.
#   A dog photo can be retaken; a signed disclaimer cannot.
# * **media/** is the dog photos.
# * **.env** holds DJANGO_SECRET_KEY and POSTGRES_PASSWORD. Without it a
#   perfectly good SQL dump still cannot bring the app back up, and every
#   session and token dies with it.
#
# ── Two limitations worth stating rather than papering over ────────────
#
# 1. These stay on the same disk as the live Postgres volume. Disk failure or
#    a lost server takes the data and every backup together. Off-site copying
#    needs a destination and credentials; it is deliberately not invented here.
# 2. A restore has never been rehearsed. Until one has, this is an untested
#    backup — see "Restoring" at the foot of this file.
#
# ── Scheduling ─────────────────────────────────────────────────────────
# Backing up only on deploy means a quiet fortnight leaves a fortnight-old
# backup, while Jess enters clients daily. Add a nightly run:
#
#   crontab -e
#   17 3 * * *  cd /root/mojo-dog-grooming && ./tools/backup.sh --label nightly \
#                 >> /var/log/mojo-backup.log 2>&1

set -euo pipefail

COMPOSE_FILE="docker-compose.prod.yml"
BACKUP_DIR="${MOJO_BACKUP_DIR:-/root/backups/mojo-dog-grooming}"
# Count-based, not age-based. With a nightly cron plus deploys this is a couple
# of weeks of history; raise MOJO_BACKUP_KEEP if the disk allows. The host runs
# eleven projects and was at 72% when this was written, so it is not unbounded.
KEEP="${MOJO_BACKUP_KEEP:-30}"

LABEL=""
if [ "${1:-}" = "--label" ]; then
    LABEL="${2:-}"
fi

if [ ! -f .env ]; then
    echo "ERROR: no .env in $(pwd) — is this the project directory?" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

echo "=== backup $STAMP ${LABEL:+($LABEL)} ==="

# ── Database ───────────────────────────────────────────────────────────
# Credentials come from .env, defaulting the way the compose file does, so
# renaming the database there cannot turn this into a silent no-op.
PGUSER=$(sed -n 's/^POSTGRES_USER=//p' .env | head -1)
PGDB=$(sed -n 's/^POSTGRES_DB=//p' .env | head -1)

if docker compose -f "$COMPOSE_FILE" ps --services --filter status=running | grep -qx db; then
    # `< /dev/null` is load-bearing, not tidiness. CI pipes the remote script
    # into `bash -se` over SSH, so stdin *is* the rest of the deploy — and
    # `docker compose exec -T` connects the container to it. Without this
    # redirect the exec can swallow the remaining lines and the deploy
    # half-runs. deploy.sh already documents the same trap for `read`.
    docker compose -f "$COMPOSE_FILE" exec -T db \
        pg_dump -U "${PGUSER:-mojo}" -d "${PGDB:-mojo}" --clean --if-exists \
        < /dev/null \
        | gzip -9 > "$BACKUP_DIR/db-$STAMP.sql.gz"

    # A dump that failed mid-write still leaves a valid gzip of very little.
    # `set -o pipefail` catches pg_dump exiting non-zero; this catches it
    # exiting zero having produced nothing useful.
    DB_BYTES=$(stat -c %s "$BACKUP_DIR/db-$STAMP.sql.gz")
    if [ "$DB_BYTES" -lt 1000 ]; then
        echo "ERROR: database dump is only ${DB_BYTES} bytes — refusing to call that a backup" >&2
        exit 1
    fi
    echo "  db     $(du -h "$BACKUP_DIR/db-$STAMP.sql.gz" | cut -f1)"
else
    # First deploy: nothing to dump yet, and that must not fail the run.
    echo "  db     skipped — container not running (first deploy?)"
fi

# ── Uploaded files ─────────────────────────────────────────────────────
FILE_DIRS=()
[ -d private-media ] && FILE_DIRS+=(private-media)
[ -d media ] && FILE_DIRS+=(media)

if [ ${#FILE_DIRS[@]} -gt 0 ]; then
    tar -czf "$BACKUP_DIR/files-$STAMP.tar.gz" "${FILE_DIRS[@]}"
    echo "  files  $(du -h "$BACKUP_DIR/files-$STAMP.tar.gz" | cut -f1) (${FILE_DIRS[*]})"
else
    echo "  files  skipped — no private-media/ or media/ yet"
fi

# ── Secrets ────────────────────────────────────────────────────────────
cp .env "$BACKUP_DIR/env-$STAMP"
chmod 600 "$BACKUP_DIR/env-$STAMP"
echo "  env    saved"

# ── Retention ──────────────────────────────────────────────────────────
# Each artefact type pruned on its own, so a run that skipped one (a first
# deploy, say) cannot shift the others out of step.
for prefix in 'db-*.sql.gz' 'files-*.tar.gz' 'env-*'; do
    # `|| true` is required, not defensive: `set -o pipefail` is on, and `ls`
    # exits non-zero when a glob matches nothing. On a first run there is no
    # files-*.tar.gz yet, so without this the whole script — and with it the
    # deploy — dies here having just taken a perfectly good backup.
    # shellcheck disable=SC2086
    { ls -1t $BACKUP_DIR/$prefix 2>/dev/null || true; } | tail -n +$((KEEP + 1)) | xargs -r rm -f
done

echo "=== kept the $KEEP most recent of each in $BACKUP_DIR ==="
df -h "$BACKUP_DIR" | tail -1

# ── Restoring ──────────────────────────────────────────────────────────
# Not automated on purpose: restoring is a decision, not a step. By hand —
#
#   cd /root/mojo-dog-grooming
#   docker compose -f docker-compose.prod.yml down
#   cp /root/backups/mojo-dog-grooming/env-<stamp> .env
#   tar -xzf /root/backups/mojo-dog-grooming/files-<stamp>.tar.gz
#   docker compose -f docker-compose.prod.yml up -d db
#   gunzip -c /root/backups/mojo-dog-grooming/db-<stamp>.sql.gz |
#     docker compose -f docker-compose.prod.yml exec -T db psql -U mojo -d mojo
#   docker compose -f docker-compose.prod.yml up -d
#
# Rehearse it against a throwaway copy before you ever need it for real.
