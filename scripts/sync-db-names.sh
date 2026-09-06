#!/usr/bin/env bash
#
# sync-db-names.sh — Renomme des bases MySQL vers la convention <env>_<slug>.
#
#   dev  -> dev_<slug>       prod -> prod_<slug>
#   (l'env-local n'est PAS concerné : on le laisse tel quel)
#
# À exécuter DIRECTEMENT sur le serveur cible (nowis, bifacto, ...).
# Auth : par défaut via le mot de passe interne au conteneur ($MYSQL_ROOT_PASSWORD),
# jamais affiché. Override possible avec DBPASS=...
#
# Méthode : dump + reload (préserve tables, vues, triggers, routines, events).
# Non destructif : l'ancienne base est CONSERVÉE tant que --drop-old n'est pas passé.
#
# USAGE :
#   ./sync-db-names.sh --list                          # inventaire (lecture seule)
#   ./sync-db-names.sh old1:new1 old2:new2             # dry-run des paires
#   ./sync-db-names.sh --apply old1:new1 old2:new2     # exécute (garde les anciennes)
#   ./sync-db-names.sh --apply --drop-old old1:new1    # exécute + DROP anciennes
#
# Overrides : CONTAINER=... DBUSER=... DBPASS=...
#
set -euo pipefail

CONTAINER="${CONTAINER:-infra_mysql_8_0}"
DBUSER="${DBUSER:-root}"
DBPASS="${DBPASS:-}"          # vide => utilise $MYSQL_ROOT_PASSWORD dans le conteneur

APPLY=0; DROP_OLD=0; LIST=0
declare -a PAIRS
for arg in "$@"; do
  case "$arg" in
    --apply)    APPLY=1;;
    --drop-old) DROP_OLD=1;;
    --list)     LIST=1;;
    --*)        echo "Option inconnue: $arg"; exit 2;;
    *:*)        PAIRS+=("$arg");;
    *)          echo "Argument invalide (attendu old:new): $arg"; exit 2;;
  esac
done

# --- exécution mysql : SQL via stdin, mot de passe jamais en argument ni affiché ---
mysql_q(){
  if [ -n "$DBPASS" ]; then
    docker exec -e MYSQL_PWD="$DBPASS" -i "$CONTAINER" mysql -u"$DBUSER" -N
  else
    docker exec -i "$CONTAINER" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u'"$DBUSER"' -N'
  fi
}
dump_pipe_reload(){ # $1=old $2=new  (dump old | mysql new), tout dans le conteneur
  local o="$1" n="$2"
  if [ -n "$DBPASS" ]; then
    docker exec -e MYSQL_PWD="$DBPASS" "$CONTAINER" sh -c \
      "mysqldump -u$DBUSER --routines --triggers --events --single-transaction '$o' | mysql -u$DBUSER '$n'"
  else
    docker exec "$CONTAINER" sh -c \
      "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\"; export MYSQL_PWD; mysqldump -u$DBUSER --routines --triggers --events --single-transaction '$o' | mysql -u$DBUSER '$n'"
  fi
}
backup_dump(){ # $1=old -> /tmp/<old>_backup.sql dans le conteneur
  local o="$1"
  if [ -n "$DBPASS" ]; then
    docker exec -e MYSQL_PWD="$DBPASS" "$CONTAINER" sh -c \
      "mysqldump -u$DBUSER --routines --triggers --events --single-transaction '$o' > /tmp/${o}_backup.sql"
  else
    docker exec "$CONTAINER" sh -c \
      "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\"; export MYSQL_PWD; mysqldump -u$DBUSER --routines --triggers --events --single-transaction '$o' > /tmp/${o}_backup.sql"
  fi
}

q(){ printf '%s\n' "$1" | mysql_q; }
replicate_grants(){ # $1=old $2=new : donne à chaque user applicatif de OLD les droits sur NEW
  local o="$1" n="$2" acct u h found=0
  for acct in $(q "SELECT CONCAT(user,'@',host) FROM mysql.db WHERE db='$o';"); do
    u="${acct%@*}"; h="${acct#*@}"; found=1
    echo "  • grant ALL sur $n -> $u@$h"
    q "GRANT ALL PRIVILEGES ON \`$n\`.* TO \`$u\`@\`$h\`;"
  done
  [ $found -eq 1 ] && q "FLUSH PRIVILEGES;" || echo "  (aucun user dédié trouvé sur $o — app connectée en root ?)"
}
db_exists(){ [ -n "$(q "SELECT schema_name FROM information_schema.schemata WHERE schema_name='$1';")" ]; }
count_tables(){ q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1' AND table_type='BASE TABLE';"; }
count_objs(){ local s="$1"
  echo "$(q "SELECT COUNT(*) FROM information_schema.views WHERE table_schema='$s';") \
$(q "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema='$s';") \
$(q "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='$s';") \
$(q "SELECT COUNT(*) FROM information_schema.events WHERE event_schema='$s';")"; }

echo "=========================================================="
echo " sync-db-names.sh  |  conteneur=$CONTAINER  user=$DBUSER"
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "❌ conteneur '$CONTAINER' introuvable"; exit 1; }

# --- mode inventaire ---
if [ $LIST -eq 1 ]; then
  echo " INVENTAIRE (lecture seule)"
  echo "=========================================================="
  q "SELECT CONCAT(schema_name,' | ',(SELECT COUNT(*) FROM information_schema.tables t WHERE t.table_schema=s.schema_name AND t.table_type='BASE TABLE'),' tables') FROM information_schema.schemata s WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY schema_name;"
  exit 0
fi

[ ${#PAIRS[@]} -eq 0 ] && { echo " (aucune paire old:new fournie — voir --list / usage en tête)"; exit 0; }
echo " Mode : $([ $APPLY -eq 1 ] && echo APPLY || echo DRY-RUN) $([ $DROP_OLD -eq 1 ] && echo '+ DROP-OLD')"
echo "=========================================================="

FAIL=0
for pair in "${PAIRS[@]}"; do
  OLD="${pair%%:*}"; NEW="${pair##*:}"
  echo ""; echo "───────────────────────────────────────────────"
  echo "  $OLD  ──►  $NEW"; echo "───────────────────────────────────────────────"

  db_exists "$OLD" || { echo "  ❌ source '$OLD' absente — ignorée."; FAIL=1; continue; }
  read -r nv nt nr ne <<<"$(count_objs "$OLD")"
  echo "  source : $(count_tables "$OLD") tables | vues:$nv triggers:$nt routines:$nr events:$ne"

  if db_exists "$NEW"; then
    echo "  ⚠️  cible '$NEW' existe déjà ($(count_tables "$NEW") tables) — collision, non écrasée."
    [ $APPLY -eq 1 ] && { FAIL=1; continue; }
  fi

  if [ $APPLY -eq 0 ]; then
    echo "  (dry-run) copierait $OLD -> $NEW (dump+reload), puis DATABASE_URL -> '$NEW'"
    continue
  fi

  echo "  • backup       -> /tmp/${OLD}_backup.sql (dans le conteneur)"; backup_dump "$OLD"
  echo "  • create       -> $NEW (utf8mb4)"; q "CREATE DATABASE IF NOT EXISTS \`$NEW\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  echo "  • copie        -> $OLD ⇒ $NEW"; dump_pipe_reload "$OLD" "$NEW"

  src=$(count_tables "$OLD"); dst=$(count_tables "$NEW")
  if [ "$src" = "$dst" ]; then
    echo "  ✅ $dst/$src tables copiées."
    echo "  • réplication des droits utilisateur"; replicate_grants "$OLD" "$NEW"
    if [ $DROP_OLD -eq 1 ]; then echo "  • DROP $OLD"; q "DROP DATABASE \`$OLD\`;"
    else echo "  ↩︎ '$OLD' conservée (rollback) — supprime après vérif avec --drop-old."; fi
  else
    echo "  ❌ écart tables ($dst/$src) — cible NON validée, ancienne intacte."; FAIL=1
  fi
done

echo ""; echo "=========================================================="
if [ $APPLY -eq 0 ]; then
  echo " Dry-run terminé. Ajoute --apply pour exécuter."
else
  echo " Terminé. Restant (manuel) : MAJ DATABASE_URL (.env.local) -> nouveaux noms,"
  echo " restart des services, vérif appli, puis --drop-old."
fi
echo "=========================================================="
exit $FAIL
