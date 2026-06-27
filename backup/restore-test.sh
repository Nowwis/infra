#!/usr/bin/env bash
#
# restore-test.sh — Test de restauration RÉEL d'une sauvegarde MySQL sur un
# environnement jetable, avec contrôles d'intégrité et mesure du RTO.
# (NOW-25)
#
# Principe :
#   1. Démarre un conteneur MySQL 8.0 JETABLE (nom aléatoire, AUCUN port publié,
#      datadir temporaire) — totalement isolé de la prod.
#   2. Restaure chaque dump *.sql.gz trouvé dans le dossier de backup.
#   3. Contrôles d'intégrité : CHECK TABLE sur toutes les tables, comptage des
#      objets (tables/vues/routines/triggers), et (optionnel) assertions de
#      nombre de lignes par table via un fichier d'attendus.
#   4. Mesure et reporte le RTO (boot + restore + checks).
#   5. Détruit le conteneur et le datadir, quoi qu'il arrive (trap EXIT).
#
# Le script NE TOUCHE JAMAIS la prod : il ne fait que LIRE des fichiers de dump.
# Sortie : code 0 = restauration vérifiée OK, !=0 = échec (intégrité ou erreur).
# Un résumé JSON est écrit dans <backup-dir>/restore-test-result.json.
#
# Usage :
#   ./restore-test.sh --backup-dir /chemin/vers/dumps [options]
#
# Options :
#   --backup-dir DIR     Dossier contenant les *.sql.gz à restaurer (obligatoire)
#   --image IMG          Image MySQL (défaut: mysql:8.0)
#   --pattern GLOB       Motif des dumps (défaut: *.sql.gz)
#   --expect FILE        Fichier "db.table<TAB>nb_lignes" pour asserter les counts
#   --keep               Ne pas détruire le conteneur en fin (debug)
#   -h|--help            Aide
#
set -euo pipefail

# --- Defaults ---------------------------------------------------------------
IMAGE="mysql:8.0"
PATTERN="*.sql.gz"
BACKUP_DIR=""
EXPECT_FILE=""
KEEP=0

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
err()  { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="$2"; shift 2;;
    --image)      IMAGE="$2"; shift 2;;
    --pattern)    PATTERN="$2"; shift 2;;
    --expect)     EXPECT_FILE="$2"; shift 2;;
    --keep)       KEEP=1; shift;;
    -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \?//'; exit 0;;
    *) err "Option inconnue: $1"; exit 2;;
  esac
done

[ -n "$BACKUP_DIR" ]  || { err "--backup-dir obligatoire"; exit 2; }
[ -d "$BACKUP_DIR" ]  || { err "Dossier introuvable: $BACKUP_DIR"; exit 2; }

# Liste des dumps
shopt -s nullglob
DUMPS=( "$BACKUP_DIR"/$PATTERN )
shopt -u nullglob
[ ${#DUMPS[@]} -gt 0 ] || { err "Aucun dump '$PATTERN' dans $BACKUP_DIR"; exit 2; }

# --- Conteneur jetable ------------------------------------------------------
CNAME="restore_probe_$$_${RANDOM}"
DATADIR="$(mktemp -d "${TMPDIR:-/tmp}/restore-probe.XXXXXX")"
ROOTPW="probe_${RANDOM}${RANDOM}${RANDOM}"
START_EPOCH=$(date +%s)
FAILED=0

cleanup() {
  if [ "$KEEP" = "1" ]; then
    log "Conteneur conservé pour debug: $CNAME (datadir $DATADIR)"
    return
  fi
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT

# --- 1. Boot ----------------------------------------------------------------
log "Démarrage du conteneur jetable $CNAME (image $IMAGE, sans port publié)…"
docker run -d --name "$CNAME" \
  -e MYSQL_ROOT_PASSWORD="$ROOTPW" \
  -v "$DATADIR":/var/lib/mysql \
  "$IMAGE" --skip-mysqlx --skip-networking=0 >/dev/null

mq() { docker exec -i "$CNAME" mysql -uroot -p"$ROOTPW" "$@" 2>/dev/null; }

boot_start=$(date +%s)
# Attente "réellement prête" : on exige qu'une requête SQL aboutisse, pas
# seulement que le healthcheck passe (le healthcheck peut être vert pendant
# l'init des tables système → on a observé une fausse réussite sans cette garde).
ready=0
for _ in $(seq 1 90); do
  if mq -N -e "SELECT 1;" >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
boot_dur=$(( $(date +%s) - boot_start ))
if [ "$ready" != "1" ]; then
  err "MySQL n'est pas devenu disponible (timeout)"
  docker logs --tail 30 "$CNAME" || true
  exit 1
fi
ok "MySQL prêt en ${boot_dur}s"

# --- 2. Restore -------------------------------------------------------------
restore_start=$(date +%s)
declare -a RESTORED_DBS=()
for f in "${DUMPS[@]}"; do
  base="$(basename "$f")"
  # Convention de nommage : <db>_<timestamp>.sql.gz  → on extrait <db>.
  # Sinon, on retombe sur le nom de fichier sans extension.
  db="$(printf '%s' "$base" | sed -E 's/_[0-9]{8}_[0-9]{6}\.sql\.gz$//; s/\.sql\.gz$//')"
  sz="$(du -h "$f" | cut -f1)"
  log "Restauration de '$db' depuis $base ($sz)…"
  if ! mq -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
    err "Création de la base $db échouée"; FAILED=1; continue
  fi
  if gunzip -c "$f" | docker exec -i "$CNAME" mysql -uroot -p"$ROOTPW" "$db" 2>/dev/null; then
    n=$(mq -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';")
    ok "$db restauré — $n objets"
    RESTORED_DBS+=( "$db" )
  else
    err "Import du dump $base échoué"; FAILED=1
  fi
done
restore_dur=$(( $(date +%s) - restore_start ))

# --- 3. Contrôles d'intégrité ----------------------------------------------
check_start=$(date +%s)
TOTAL_TABLES=0; TOTAL_BAD=0
for db in "${RESTORED_DBS[@]}"; do
  tables=$(mq -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$db' AND table_type='BASE TABLE';")
  cnt=0; bad=0
  for t in $tables; do
    cnt=$((cnt+1)); TOTAL_TABLES=$((TOTAL_TABLES+1))
    res=$(mq -N -e "CHECK TABLE \`$db\`.\`$t\`;" | awk -F'\t' '{print $NF}')
    if [ "$res" != "OK" ]; then err "CHECK TABLE $db.$t -> $res"; bad=$((bad+1)); TOTAL_BAD=$((TOTAL_BAD+1)); fi
  done
  if [ "$bad" = 0 ]; then ok "$db : $cnt tables, CHECK TABLE OK"; else err "$db : $bad/$cnt tables NON-OK"; FAILED=1; fi
done

# --- 3b. Assertions de comptage (optionnel) --------------------------------
if [ -n "$EXPECT_FILE" ] && [ -f "$EXPECT_FILE" ]; then
  log "Assertions de nombre de lignes ($EXPECT_FILE)…"
  while IFS=$'\t' read -r key expected; do
    [ -z "${key:-}" ] && continue
    case "$key" in \#*) continue;; esac
    db="${key%%.*}"; tbl="${key#*.}"
    actual=$(mq -N -e "SELECT COUNT(*) FROM \`$db\`.\`$tbl\`;" || echo "ERR")
    if [ "$actual" = "$expected" ]; then ok "$key = $actual"; else err "$key attendu=$expected obtenu=$actual"; FAILED=1; fi
  done < "$EXPECT_FILE"
fi
check_dur=$(( $(date +%s) - check_start ))

# --- 4. RTO + rapport JSON --------------------------------------------------
rto=$(( $(date +%s) - START_EPOCH ))
status="ok"; [ "$FAILED" = 0 ] || status="failed"
total_bytes=0
for f in "${DUMPS[@]}"; do total_bytes=$(( total_bytes + $(stat -c%s "$f") )); done

RESULT="$BACKUP_DIR/restore-test-result.json"
cat > "$RESULT" <<JSON
{
  "status": "$status",
  "image": "$IMAGE",
  "backup_dir": "$BACKUP_DIR",
  "dumps": ${#DUMPS[@]},
  "databases_restored": ${#RESTORED_DBS[@]},
  "tables_checked": $TOTAL_TABLES,
  "tables_non_ok": $TOTAL_BAD,
  "backup_bytes": $total_bytes,
  "timing_seconds": { "boot": $boot_dur, "restore": $restore_dur, "checks": $check_dur, "rto_total": $rto }
}
JSON

echo
log "Résumé : status=$status  RTO=${rto}s  (boot ${boot_dur}s / restore ${restore_dur}s / checks ${check_dur}s)"
log "         $TOTAL_TABLES tables vérifiées, $TOTAL_BAD non-OK — rapport: $RESULT"

exit "$FAILED"
