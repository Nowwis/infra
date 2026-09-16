#!/bin/sh
# Rotate the Traefik access log — rootless & portable (no logrotate dependency,
# works on hosts where logrotate/sudo are unavailable, e.g. bifacto).
#
# Strategy: when access.log reaches MAXSIZE, shift the gzipped rotations,
# move the current log aside, tell Traefik to reopen its log file via SIGUSR1
# (Traefik recreates access.log), then gzip the rotated file.
#
# Wire it via the host user crontab, e.g. every 6h:
#   0 */6 * * * /home/webadmin/Infra/configuration/traefik2/rotate-logs.sh >> /home/webadmin/Infra/configuration/traefik2/logs/rotate.log 2>&1
set -eu

LOGDIR="${LOGDIR:-/home/webadmin/Infra/configuration/traefik2/logs}"
LOG="$LOGDIR/access.log"
MAXSIZE="${MAXSIZE:-52428800}"   # 50 MiB
ROTATIONS="${ROTATIONS:-7}"      # keep access.log.1.gz .. access.log.N.gz
CONTAINER="${CONTAINER:-infra_traefik}"

[ -f "$LOG" ] || exit 0
SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
[ "$SIZE" -ge "$MAXSIZE" ] || exit 0

# Shift older compressed rotations up (drops the oldest beyond ROTATIONS).
i="$ROTATIONS"
while [ "$i" -gt 1 ]; do
  prev=$((i - 1))
  [ -f "$LOG.$prev.gz" ] && mv -f "$LOG.$prev.gz" "$LOG.$i.gz"
  i="$prev"
done

mv -f "$LOG" "$LOG.1"
# Traefik reopens access.log (creates a fresh file) on SIGUSR1.
docker kill -s USR1 "$CONTAINER" >/dev/null 2>&1 || true
# Give Traefik a moment to release the old inode before compressing it.
sleep 1
gzip -f "$LOG.1"

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') rotated access.log (was ${SIZE} bytes)"
