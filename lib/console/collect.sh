# shellcheck shell=bash
# lib/console/collect.sh — cadre du collecteur : sections, cadences, écriture atomique,
# assemblage de l'instantané (docs/2026-09-15-work-console-design.md §5.2).
: "${CONSOLE_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
: "${CONSOLE_STATE:=$HOME/.local/state/console}"
: "${CONSOLE_PROC:=/proc}"
: "${CONSOLE_SESSIONS_DIR:=$HOME/.claude/sessions}"
CONSOLE_SECTIONS_DIR="$CONSOLE_STATE/sections"

# section:cadence (secondes). Les sections lentes tournent en tâche de fond.
CONSOLE_CADENCES="system:2 sessions:5 activity:5 projects:10 docker:15 diagnostics:15 disk:60 prs:300 docker_df:600"
CONSOLE_BACKGROUND="prs docker_df"

console_die() { printf 'console-collector : %s\n' "$*" >&2; exit 1; }

console_cadence() { # section → cadence
  local e
  for e in $CONSOLE_CADENCES; do
    [ "${e%%:*}" = "$1" ] && { printf '%s' "${e#*:}"; return 0; }
  done
  return 1
}

console_default_data() { # section → data par défaut quand la source est indisponible
  case "$1" in
    system|prs) printf '{}' ;;
    sessions) printf '{"items":[],"mcp_orphans":[]}' ;;
    *) printf '[]' ;;
  esac
}

console_has_section() { [ -f "$CONSOLE_ROOT/lib/console/section_$1.sh" ]; }

# Projets de `work` : [{name, repo, forge}] — rattachement des conteneurs et sessions,
# et choix de la forge pour la section prs.
console_work_projects() {
  local conf="${WORK_CONF:-$CONSOLE_ROOT/etc/work/projects.conf}"
  [ -f "$conf" ] || { printf '[]'; return 0; }
  awk -F'|' '!/^#/ && NF >= 5 {printf "%s\t%s\t%s\n", $1, $2, $5}' "$conf" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], repo: .[1], forge: .[2]})'
}

# Journaux d'activité exploités : la veille puis aujourd'hui (une session à cheval sur minuit
# reste lisible). Utilisés par les sections activity et sessions.
console_journal_files() {
  printf '%s\n%s\n' \
    "$CONSOLE_STATE/events-$(date -u -d '-1 day' +%Y-%m-%d).jsonl" \
    "$CONSOLE_STATE/events-$(date -u +%Y-%m-%d).jsonl"
}

# Rétention 7 jours. La date vient du NOM du fichier, pas de sa date de modification :
# un vieux journal réécrit aujourd'hui doit tout de même partir.
console_journal_purge() {
  local cutoff f day
  cutoff="$(date -u -d '-7 days' +%Y-%m-%d)"
  for f in "$CONSOLE_STATE"/events-*.jsonl; do
    [ -f "$f" ] || continue
    day="${f##*/events-}"; day="${day%.jsonl}"
    [[ "$day" < "$cutoff" ]] && rm -f "$f"
  done
  return 0
}

# Événements des journaux exploités, triés du plus ancien au plus récent.
console_journal_events() {
  local f files=()
  while IFS= read -r f; do [ -f "$f" ] && files+=("$f"); done < <(console_journal_files)
  if [ "${#files[@]}" -eq 0 ]; then printf '[]'; return 0; fi
  cat "${files[@]}" 2>/dev/null \
    | jq -s -c 'map(select(type == "object")) | sort_by(.ts // "")' 2>/dev/null
}

console_write_atomic() { # fichier (contenu sur stdin)
  local f="$1" tmp="$1.tmp.$$"
  mkdir -p "$(dirname "$f")"
  cat > "$tmp" && mv "$tmp" "$f"
}

console_once() { # section
  local name="$1" cad data out
  [ -n "$name" ] || console_die "usage : console-collector once <section>"
  cad="$(console_cadence "$name")" || console_die "section inconnue : $name"
  console_has_section "$name" || console_die "section non implémentée : $name"
  source "$CONSOLE_ROOT/lib/console/section_$name.sh"

  data="$("section_$name" 2>/dev/null)"
  jq -e . >/dev/null 2>&1 <<<"$data" || data="$(console_default_data "$name")"
  out="$(jq -c -n --argjson d "$data" --argjson c "$cad" --argjson t "$(date +%s)" \
        '{collected_at: $t, cadence: $c, data: $d}')" || return 1
  printf '%s\n' "$out" | console_write_atomic "$CONSOLE_SECTIONS_DIR/$name.json"
  printf '%s\n' "$out"
}

console_assemble() {
  local out='{}' f name snap
  for f in "$CONSOLE_SECTIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .json)"
    out="$(jq -c --arg n "$name" --slurpfile s "$f" '.[$n] = $s[0]' <<<"$out")" || continue
  done
  snap="$(jq -c -n --argjson s "$out" --argjson t "$(date +%s)" '{generated_at: $t, sections: $s}')" || return 1
  printf '%s\n' "$snap" | console_write_atomic "$CONSOLE_STATE/snapshot.json"
  printf '%s\n' "$snap"
}

# Section lente : verrou non bloquant, pour qu'une collecte lente ne s'empile jamais sur elle-même.
console_spawn() { # section
  local lock="$CONSOLE_STATE/locks/$1.lock"
  mkdir -p "$(dirname "$lock")"
  ( flock -n 9 || exit 0; console_once "$1" >/dev/null 2>&1 ) 9>"$lock" &
}

console_collect() { # section : en tâche de fond si elle est lente
  case " $CONSOLE_BACKGROUND " in
    *" $1 "*) console_spawn "$1" ;;
    *) console_once "$1" >/dev/null 2>&1 ;;
  esac
}

console_run() {
  local tick=0 max="${CONSOLE_RUN_TICKS:-0}" e name cad
  # Amorçage : une collecte de chaque section disponible, sans attendre sa cadence.
  for e in $CONSOLE_CADENCES; do
    name="${e%%:*}"
    console_has_section "$name" && console_collect "$name"
  done
  console_assemble >/dev/null

  while :; do
    tick=$((tick + 1))
    for e in $CONSOLE_CADENCES; do
      name="${e%%:*}"; cad="${e#*:}"
      console_has_section "$name" || continue
      [ $((tick % cad)) -eq 0 ] || continue
      console_collect "$name"
    done
    console_assemble >/dev/null
    if [ "$max" -gt 0 ] && [ "$tick" -ge "$max" ]; then break; fi
    sleep 1
  done
  return 0
}
