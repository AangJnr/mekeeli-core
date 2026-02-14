#!/bin/sh
set -eu

log() {
  printf '[backup] %s\n' "$1"
}

require_var() {
  name="$1"
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    log "Missing required environment variable: $name"
    exit 1
  fi
}

require_var PGHOST
require_var PGUSER
require_var PGPASSWORD
require_var PGDATABASE

BACKUP_DIR="${BACKUP_DIR:-/backups}"
APP_DATA_DIR="${APP_DATA_DIR:-/app-data}"
UPLOADS_DIR="${UPLOADS_DIR:-/uploads-data}"
OLLAMA_DATA_DIR="${OLLAMA_DATA_DIR:-/ollama-data}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_OLLAMA_MODELS="${BACKUP_OLLAMA_MODELS:-true}"

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
run_dir="$BACKUP_DIR/$timestamp"
mkdir -p "$run_dir"

log "Starting backup run: $timestamp"

# Logical database backup is consistent and portable across host upgrades.
pg_dump \
  --host="$PGHOST" \
  --port="${PGPORT:-5432}" \
  --username="$PGUSER" \
  --no-owner \
  --no-acl \
  "$PGDATABASE" | gzip > "$run_dir/postgres.sql.gz"

if [ -d "$APP_DATA_DIR" ]; then
  tar -czf "$run_dir/app-data.tar.gz" -C "$APP_DATA_DIR" .
fi

if [ -d "$UPLOADS_DIR" ]; then
  tar -czf "$run_dir/uploads-data.tar.gz" -C "$UPLOADS_DIR" .
fi

if [ "$BACKUP_OLLAMA_MODELS" = "true" ] && [ -d "$OLLAMA_DATA_DIR" ]; then
  tar -czf "$run_dir/ollama-data.tar.gz" -C "$OLLAMA_DATA_DIR" .
fi

cat > "$run_dir/manifest.txt" <<EOF
created_at_utc=$timestamp
pg_host=$PGHOST
pg_database=$PGDATABASE
includes_app_data=$( [ -d "$APP_DATA_DIR" ] && echo true || echo false )
includes_uploads_data=$( [ -d "$UPLOADS_DIR" ] && echo true || echo false )
includes_ollama_models=$BACKUP_OLLAMA_MODELS
EOF

if [ "$RETENTION_DAYS" -ge 0 ] 2>/dev/null; then
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} \;
fi

log "Backup completed: $run_dir"
