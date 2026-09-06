#!/usr/bin/env bash
#
# weekly-restore-check.sh — Vérification hebdomadaire automatisée des
# sauvegardes : dump RÉEL des bases prod (lecture seule), restauration sur un
# env jetable via restore-test.sh, contrôle de taille anormale, et ALERTE en
# cas d'échec. (NOW-25)
#
# Étapes :
#   1. Dump read-only (--single-transaction) de chaque base listée, streamé en
#      gzip depuis le conteneur prod (rien n'est écrit sur le disque prod).
#   2. restore-test.sh : restauration + CHECK TABLE + mesure RTO sur jetable.
#   3. Contrôle de taille : compare la taille du dump à la médiane des N
#      dernières exécutions (historique CSV, un point par jour). Seuils
#      ASYMÉTRIQUES : un dump qui rétrécit est une alerte (perte de données
#      probable), un dump qui grossit est un simple avertissement (croissance
#      métier normale).
#   4. Alerte (échec de restore OU rétrécissement OU dump vide) par e-mail
#      SMTP et/ou webhook, exit 1. Croissance forte → e-mail d'avertissement
#      mais exit 0. Succès → log seulement (option --notify-success).
#
# Conçu pour tourner via systemd timer (voir backup/systemd/) ou cron.
# Idempotent, sans état partagé hormis l'historique CSV.
#
# Config par variables d'environnement (voir backup/backup.env.example) :
#   PROD_SSH_HOST       hôte ssh de la prod (ex: bifacto)
#   PROD_DB_CONTAINER   conteneur MySQL prod (défaut: infra_mysql_8_0)
#   BACKUP_DATABASES    liste de bases séparées par des espaces
#   SIZE_SHRINK_PCT     rétrécissement max toléré, ALERTE au-delà (défaut: 25)
#   SIZE_GROWTH_PCT     croissance max tolérée, AVERTISSEMENT au-delà (déf: 100)
#   HISTORY_WINDOW      nb de jours d'historique pour la médiane (défaut: 8)
#   SIZE_DEVIATION_PCT  OBSOLÈTE (ancien seuil symétrique) — ignoré.
#   ALERT_EMAIL_TO      destinataire des alertes (active l'alerte mail)
#   ALERT_SMTP_HOST/PORT/FROM   serveur SMTP (défaut: localhost:1025 = mailpit)
#   ALERT_WEBHOOK_URL   URL POST JSON pour alerte (Slack/Discord/générique)
#   HISTORY_FILE        CSV d'historique (défaut: backup/.restore-history.csv)
#   WORK_ROOT           dossier de travail (défaut: /tmp)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Charge la config si un fichier backup.env est présent à côté du script.
[ -f "$SCRIPT_DIR/backup.env" ] && . "$SCRIPT_DIR/backup.env"

PROD_SSH_HOST="${PROD_SSH_HOST:-bifacto}"
PROD_DB_CONTAINER="${PROD_DB_CONTAINER:-infra_mysql_8_0}"
BACKUP_DATABASES="${BACKUP_DATABASES:-appbifacto docbifacto}"
SIZE_SHRINK_PCT="${SIZE_SHRINK_PCT:-25}"
SIZE_GROWTH_PCT="${SIZE_GROWTH_PCT:-100}"
HISTORY_WINDOW="${HISTORY_WINDOW:-8}"
HISTORY_FILE="${HISTORY_FILE:-$SCRIPT_DIR/.restore-history.csv}"
WORK_ROOT="${WORK_ROOT:-/tmp}"
ALERT_SMTP_HOST="${ALERT_SMTP_HOST:-localhost}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-1025}"
ALERT_SMTP_FROM="${ALERT_SMTP_FROM:-backup-check@nowis.fr}"
NOTIFY_SUCCESS="${NOTIFY_SUCCESS:-0}"

[ "${1:-}" = "--notify-success" ] && NOTIFY_SUCCESS=1

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
err() { printf '\033[31m  ✗\033[0m %s\n' "$*" >&2; }

# Exécute sur l'hôte prod le script lu sur stdin. Si PROD_SSH_HOST est vide ou
# "local"/"localhost", on tourne directement en local (cas : script lancé SUR la
# prod) — sinon via ssh.
run_prod() {
  case "${PROD_SSH_HOST:-}" in
    ""|local|localhost|127.0.0.1) bash -se ;;
    *) ssh -o ConnectTimeout=10 "$PROD_SSH_HOST" bash -se ;;
  esac
}

TS="$(date +%Y%m%d_%H%M%S)"
WORK="$(mktemp -d "$WORK_ROOT/restore-check.XXXXXX")"
ALERTS=()       # anomalies bloquantes (exit 1)
WARNINGS=()     # signaux non bloquants (e-mail informatif, exit 0)
trap 'rm -rf "$WORK"' EXIT

# --- alerting ---------------------------------------------------------------
send_alert() {
  local subject="$1" body="$2"
  err "ALERTE: $subject"
  # E-mail via API Brevo (HTTPS, canal fiable en prod). Forcer IPv4 : la clé
  # Brevo est restreinte par IP allow-list (l'IPv6 du serveur n'y est pas).
  if [ -n "${ALERT_BREVO_API_KEY:-}" ] && [ -n "${ALERT_EMAIL_TO:-}" ]; then
    local json
    json=$(ALERT_SUBJECT="$subject" ALERT_BODY="$body" ALERT_TO="$ALERT_EMAIL_TO" \
      ALERT_FROM="${ALERT_BREVO_SENDER:-$ALERT_SMTP_FROM}" python3 -c '
import json,os
print(json.dumps({
  "sender":{"email":os.environ["ALERT_FROM"]},
  "to":[{"email":os.environ["ALERT_TO"]}],
  "subject":"[NOW backup] "+os.environ["ALERT_SUBJECT"],
  "textContent":os.environ["ALERT_BODY"],
}))')
    if curl -4 -fsS -m 20 -X POST https://api.brevo.com/v3/smtp/email \
        -H "api-key: $ALERT_BREVO_API_KEY" -H 'Content-Type: application/json' \
        -d "$json" >/dev/null 2>&1; then
      log "Alerte e-mail (Brevo) envoyée à $ALERT_EMAIL_TO"
    else
      err "Échec envoi e-mail Brevo"
    fi
  # E-mail (SMTP brut, sans dépendance — fonctionne avec mailpit en local)
  elif [ -n "${ALERT_EMAIL_TO:-}" ]; then
    {
      printf 'EHLO localhost\r\n'; sleep 0.2
      printf 'MAIL FROM:<%s>\r\n' "$ALERT_SMTP_FROM"; sleep 0.2
      printf 'RCPT TO:<%s>\r\n' "$ALERT_EMAIL_TO"; sleep 0.2
      printf 'DATA\r\n'; sleep 0.2
      printf 'From: %s\r\nTo: %s\r\nSubject: [NOW backup] %s\r\n\r\n%s\r\n.\r\n' \
        "$ALERT_SMTP_FROM" "$ALERT_EMAIL_TO" "$subject" "$body"; sleep 0.2
      printf 'QUIT\r\n'
    } | timeout 15 bash -c "exec 3<>/dev/tcp/$ALERT_SMTP_HOST/$ALERT_SMTP_PORT; cat >&3; cat <&3 >/dev/null" \
      && log "Alerte e-mail envoyée à $ALERT_EMAIL_TO" || err "Échec envoi e-mail"
  fi
  # Webhook JSON générique
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    local json; json=$(printf '{"text":"[NOW backup] %s\n%s"}' "$subject" "${body//$'\n'/\\n}")
    curl -fsS -m 15 -H 'Content-Type: application/json' -d "$json" "$ALERT_WEBHOOK_URL" >/dev/null \
      && log "Alerte webhook envoyée" || err "Échec envoi webhook"
  fi
}

# --- historique de taille ---------------------------------------------------
[ -f "$HISTORY_FILE" ] || echo "# ts,db,bytes" > "$HISTORY_FILE"

# Médiane des tailles historiques d'une base, sur une FENÊTRE GLISSANTE des
# HISTORY_WINDOW derniers JOURS. Un seul point par jour (le dernier) : plusieurs
# runs le même jour (calibration, relance manuelle) ne doivent pas peser
# plusieurs fois et figer la médiane sur une valeur ancienne.
median_bytes() {
  awk -F, -v db="$1" '$2==db {
        split($1, t, "_");
        if (!(t[1] in last)) order[++n] = t[1];
        last[t[1]] = $3;
      }
      END { for (i = 1; i <= n; i++) print last[order[i]] }' "$HISTORY_FILE" \
    | tail -n "$HISTORY_WINDOW" | sort -n \
    | awk '{a[NR]=$1} END{if(NR==0){print 0}else if(NR%2){print a[(NR+1)/2]}else{print int((a[NR/2]+a[NR/2+1])/2)}}'
}

# --- 1. Dump read-only de la prod ------------------------------------------
log "Dump read-only des bases [$BACKUP_DATABASES] depuis $PROD_SSH_HOST:$PROD_DB_CONTAINER…"
for db in $BACKUP_DATABASES; do
  out="$WORK/${db}_${TS}.sql.gz"
  if ! run_prod > "$out" <<REMOTE
set -euo pipefail
RP=\$(docker inspect $PROD_DB_CONTAINER --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^MYSQL_ROOT_PASSWORD=//p')
[ -n "\$RP" ] || { echo "MYSQL_ROOT_PASSWORD introuvable" >&2; exit 1; }
docker exec -i -e MYSQL_PWD="\$RP" $PROD_DB_CONTAINER \
  mysqldump --single-transaction --no-tablespaces --routines --triggers --hex-blob -uroot $db | gzip -6
REMOTE
  then
    ALERTS+=("Dump de '$db' ÉCHOUÉ (ssh/mysqldump).")
    continue
  fi
  # gzip valide et non vide ?
  if ! gzip -t "$out" 2>/dev/null || [ ! -s "$out" ]; then
    ALERTS+=("Dump de '$db' invalide ou vide ($(du -h "$out"|cut -f1)).")
    continue
  fi
  bytes=$(stat -c%s "$out")
  # Contrôle de taille vs médiane glissante — seuils asymétriques : un dump qui
  # rétrécit signale une perte de données ou un dump tronqué (bloquant) ; un
  # dump qui grossit signale une croissance métier (informatif).
  med=$(median_bytes "$db")
  if [ "$med" -gt 0 ]; then
    lo=$(( med * (100 - SIZE_SHRINK_PCT) / 100 ))
    hi=$(( med * (100 + SIZE_GROWTH_PCT) / 100 ))
    if [ "$bytes" -lt "$lo" ]; then
      ALERTS+=("Rétrécissement anormal '$db' : ${bytes}o vs médiane ${med}o (max -${SIZE_SHRINK_PCT}%) — dump tronqué ou perte de données ?")
    elif [ "$bytes" -gt "$hi" ]; then
      WARNINGS+=("Croissance forte '$db' : ${bytes}o vs médiane ${med}o (max +${SIZE_GROWTH_PCT}%) — à confirmer côté métier.")
    fi
  fi
  echo "$TS,$db,$bytes" >> "$HISTORY_FILE"
  log "  $db : $(du -h "$out"|cut -f1) (médiane hist. $(numfmt --to=iec ${med} 2>/dev/null || echo ${med}o))"
done

# --- 2. Restauration jetable + intégrité -----------------------------------
log "Test de restauration sur env jetable…"
if "$SCRIPT_DIR/restore-test.sh" --backup-dir "$WORK"; then
  RESTORE_OK=1
else
  RESTORE_OK=0
  ALERTS+=("Restauration/intégrité ÉCHOUÉE — voir restore-test-result.json.")
fi
RESULT_JSON="$(cat "$WORK/restore-test-result.json" 2>/dev/null || echo '{}')"

# --- 3. Verdict + alerte ----------------------------------------------------
NB_DB="$(echo "$BACKUP_DATABASES" | wc -w)"

# Anomalie bloquante : restauration KO, dump vide/invalide, ou rétrécissement.
if [ ${#ALERTS[@]} -gt 0 ]; then
  body="Échec du contrôle hebdo de restauration ($TS) :"$'\n'
  for a in "${ALERTS[@]}"; do body+="- $a"$'\n'; done
  if [ ${#WARNINGS[@]} -gt 0 ]; then
    body+=$'\n'"Avertissements (non bloquants) :"$'\n'
    for w in "${WARNINGS[@]}"; do body+="- $w"$'\n'; done
  fi
  body+=$'\n'"Détail : $RESULT_JSON"
  send_alert "ÉCHEC contrôle restauration ($NB_DB bases)" "$body"
  exit 1
fi

# Restauration OK mais croissance notable : on informe sans crier à l'échec.
if [ ${#WARNINGS[@]} -gt 0 ]; then
  body="Restauration VÉRIFIÉE OK ($TS) — aucune anomalie bloquante."$'\n\n'
  body+="Avertissements de volumétrie :"$'\n'
  for w in "${WARNINGS[@]}"; do body+="- $w"$'\n'; done
  body+=$'\n'"Détail : $RESULT_JSON"
  send_alert "Avertissement volumétrie ($NB_DB bases) — restauration OK" "$body"
  log "Contrôle hebdo OK — restauration vérifiée, avertissement(s) de volumétrie."
  exit 0
fi

log "Contrôle hebdo OK — restauration vérifiée, tailles nominales."
if [ "$NOTIFY_SUCCESS" = "1" ]; then
  send_alert "OK contrôle restauration" "Restauration vérifiée le $TS.\n$RESULT_JSON"
fi
exit 0
