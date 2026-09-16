# shellcheck shell=bash
# Section diagnostics : constats warn/crit calculés sur les sections déjà collectées.
# Un système sain produit une liste vide. Chaque constat porte {id, level, title, detail, action}.

CONSOLE_EXPECTED_SECTIONS="system disk docker sessions projects"

_console_sec_data() { jq -c '.data' "$CONSOLE_SECTIONS_DIR/$1.json" 2>/dev/null; }

# Sections absentes ou périmées (âge > 3 × cadence).
_console_stale_sections() {
  local s f age cad now out=""
  now="$(date +%s)"
  for s in $CONSOLE_EXPECTED_SECTIONS; do
    f="$CONSOLE_SECTIONS_DIR/$s.json"
    if [ ! -f "$f" ]; then out="$out $s:absente"; continue; fi
    age=$(( now - $(jq -r '.collected_at // 0' "$f" 2>/dev/null) ))
    cad="$(jq -r '.cadence // 1' "$f" 2>/dev/null)"
    [ "$age" -gt $(( cad * 3 )) ] && out="$out $s:périmée"
  done
  printf '%s' "${out# }"
}

# Hausse du compteur OOM depuis plus de 24 h ; l'historique est conservé 48 h.
_console_oom_delta() { # valeur courante → delta (0 si pas de référence)
  local current="$1" file="$CONSOLE_STATE/oom_history" now baseline="" ts val
  now="$(date +%s)"
  if [ -f "$file" ]; then
    while read -r ts val; do
      [ -n "${val:-}" ] || continue
      [ $(( now - ts )) -ge 86400 ] && baseline="$val"
    done < "$file"
    awk -v cut=$(( now - 172800 )) '$1 >= cut' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  fi
  mkdir -p "$CONSOLE_STATE"
  printf '%s %s\n' "$now" "$current" >> "$file"
  [ -n "$baseline" ] && printf '%s' $(( current - baseline )) || printf '0'
}

# Redémarrages de conteneurs depuis le passage précédent : {"nom": delta}
_console_docker_restart_deltas() { # docker JSON
  local file="$CONSOLE_STATE/docker_restarts.json" previous current deltas
  previous="$(cat "$file" 2>/dev/null)"
  jq -e . >/dev/null 2>&1 <<<"${previous:-}" || previous='{}'
  current="$(jq -c 'map({key: .name, value: (.restarts // 0)}) | from_entries' <<<"$1" 2>/dev/null)"
  [ -n "$current" ] || current='{}'
  deltas="$(jq -c -n --argjson p "$previous" --argjson c "$current" \
    '$c | to_entries | map({key: .key, value: (.value - ($p[.key] // .value))}) | from_entries')"
  mkdir -p "$CONSOLE_STATE"
  printf '%s' "$current" > "$file"
  printf '%s' "${deltas:-\{\}}"
}

section_diagnostics() {
  local sys disk docker sessions projects stale oom_delta restart_deltas failed_units
  sys="$(_console_sec_data system)"; jq -e . >/dev/null 2>&1 <<<"${sys:-}" || sys='{}'
  disk="$(_console_sec_data disk)"; jq -e . >/dev/null 2>&1 <<<"${disk:-}" || disk='[]'
  docker="$(_console_sec_data docker)"; jq -e . >/dev/null 2>&1 <<<"${docker:-}" || docker='[]'
  sessions="$(_console_sec_data sessions)"; jq -e . >/dev/null 2>&1 <<<"${sessions:-}" || sessions='{"items":[],"mcp_orphans":[]}'
  projects="$(_console_sec_data projects)"; jq -e . >/dev/null 2>&1 <<<"${projects:-}" || projects='[]'

  stale="$(_console_stale_sections)"
  oom_delta="$(_console_oom_delta "$(jq -r '.oom_kill_total // 0' <<<"$sys")")"
  restart_deltas="$(_console_docker_restart_deltas "$docker")"
  # init.scope est toujours en échec sur cet hôte : ce n'est pas un signal.
  failed_units="$(systemctl --user --failed --no-legend --plain 2>/dev/null \
    | awk '{print $1}' | grep -v '^init\.scope$' | paste -sd, -)"

  jq -c -n --argjson sys "$sys" --argjson disk "$disk" --argjson docker "$docker" \
     --argjson sessions "$sessions" --argjson projects "$projects" \
     --argjson restarts "$restart_deltas" --argjson oom "${oom_delta:-0}" \
     --arg stale "$stale" --arg failed "$failed_units" '
    def f($id; $level; $title; $detail; $action): {id: $id, level: $level, title: $title, detail: $detail, action: $action};
    def pct($x): (($x * 100) | floor | tostring);

    [
      # Mémoire disponible
      (if ($sys.mem_total_kb // 0) > 0 then
         (($sys.mem_avail_kb / $sys.mem_total_kb) as $r
          | if $r < 0.10 then f("ram"; "crit"; "Mémoire disponible critique"; pct($r) + " % de RAM disponible";
                                "Fermer des sessions inactives ou arrêter des stacks Docker inutilisées")
            elif $r < 0.20 then f("ram"; "warn"; "Mémoire disponible faible"; pct($r) + " % de RAM disponible";
                                "Surveiller les sessions et stacks les plus gourmandes")
            else empty end)
       else empty end),

      # Swap
      (if ($sys.swap_total_kb // 0) > 0 then
         (($sys.swap_used_kb / $sys.swap_total_kb) as $r
          | if $r > 0.80 then f("swap"; "crit"; "Swap presque plein"; pct($r) + " % du swap utilisé";
                                "Libérer de la RAM : le thrashing fait grimper le CPU")
            elif $r > 0.50 then f("swap"; "warn"; "Swap très utilisé"; pct($r) + " % du swap utilisé";
                                "Vérifier les processus les plus gourmands")
            else empty end)
       else empty end),

      # Pression mémoire (PSI)
      (($sys.psi.mem_some_avg60 // 0) as $p
       | if $p > 25 then f("psi-memory"; "crit"; "Pression mémoire critique"; "PSI mémoire some avg60 = " + ($p | tostring);
                           "Les processus attendent la mémoire : libérer de la RAM")
         elif $p > 10 then f("psi-memory"; "warn"; "Pression mémoire"; "PSI mémoire some avg60 = " + ($p | tostring);
                           "Surveiller la consommation mémoire")
         else empty end),

      # Pression disque (PSI)
      (($sys.psi.io_some_avg60 // 0) as $p
       | if $p > 40 then f("psi-io"; "crit"; "Pression disque critique"; "PSI io some avg60 = " + ($p | tostring);
                           "Identifier les écritures massives (logs, dumps, build)")
         elif $p > 20 then f("psi-io"; "warn"; "Pression disque"; "PSI io some avg60 = " + ($p | tostring);
                           "Surveiller les entrées/sorties")
         else empty end),

      # Disques
      ($disk[]? | select((.use_pct // 0) > 85)
       | f("disk:" + .mount;
           (if .use_pct > 95 then "crit" else "warn" end);
           "Disque " + .mount + " presque plein";
           (.use_pct | tostring) + " % utilisés";
           "Faire le ménage (docker system prune, logs, dumps)")),

      # Processus tués faute de mémoire
      (if $oom > 0 then
         f("oom"; "warn"; "Processus tués par manque de mémoire";
           ($oom | tostring) + " kill(s) OOM sur les dernières 24 h";
           "Identifier le processus visé et réduire la charge mémoire")
       else empty end),

      # Conteneurs en mauvaise santé
      ($docker[]? | select(.health == "unhealthy")
       | f("docker-health:" + .name; "warn"; "Conteneur en mauvaise santé";
           .name + " (projet " + (.project // "?") + ") est unhealthy";
           "Regarder docker compose logs de ce service")),

      # Conteneurs qui redémarrent
      ($docker[]? | . as $c | ($restarts[$c.name] // 0) as $d | select($d > 0)
       | f("docker-restarts:" + $c.name;
           (if $d >= 3 then "crit" else "warn" end);
           "Conteneur qui redémarre";
           $c.name + " : " + ($d | tostring) + " redémarrage(s) depuis le dernier passage";
           "Vérifier les logs et la cause du crash")),

      # Unités systemd utilisateur en échec
      (if $failed != "" then
         f("systemd-failed"; "warn"; "Unité systemd utilisateur en échec"; $failed;
           "systemctl --user status <unité> pour la cause")
       else empty end),

      # Serveurs MCP orphelins
      (($sessions.mcp_orphans // [] | map(.count) | add // 0) as $n
       | if $n > 10 then f("mcp-orphans"; "crit"; "Serveurs MCP orphelins";
                           ($n | tostring) + " processus MCP hors de toute session vivante";
                           "Les arrêter : ils gardent de la RAM pour rien")
         elif $n > 3 then f("mcp-orphans"; "warn"; "Serveurs MCP orphelins";
                           ($n | tostring) + " processus MCP hors de toute session vivante";
                           "Vérifier les sessions fantômes")
         else empty end),

      # Verrous work tenus par une session terminée
      ($projects[]? | select((.drift // []) | index("verrou-orphelin"))
       | f("work-lock:" + .name; "warn"; "Verrou work orphelin";
           "Ticket " + (.ticket // "?") + " (" + (.branch // "?") + ") tenu par une session terminée";
           "work takeover depuis ce projet, si Simon le demande")),

      # Sources indisponibles
      ($stale | select(length > 0) | split(" ")[]
       | split(":") as $s
       | f("source:" + $s[0]; "warn"; "Source indisponible";
           "Section " + $s[0] + " " + $s[1];
           "Vérifier le service console-collector"))
    ]'
}
