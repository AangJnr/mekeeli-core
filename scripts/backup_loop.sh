#!/bin/sh
set -eu

INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"
if [ "$INTERVAL" -lt 60 ] 2>/dev/null; then
  INTERVAL=60
fi

printf '[backup] Scheduled backups enabled. Interval=%ss\n' "$INTERVAL"

while true; do
  if /bin/sh /scripts/backup_once.sh; then
    printf '[backup] Run succeeded.\n'
  else
    printf '[backup] Run failed.\n'
  fi
  sleep "$INTERVAL"
done
