# shellcheck shell=bash
# Section docker : un objet par conteneur (état, projet, CPU, mémoire, redémarrages, santé).
# Le projet affiché est celui de `work` dont le repo contient le working_dir du conteneur,
# sinon le projet compose, sinon le nom du conteneur.

_console_tsv_json() { jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))'; }

section_docker() {
  local fmt_ps fmt_stats fmt_insp ps stats insp ids projects
  fmt_ps='{{.Names}}'$'\t''{{.State}}'$'\t''{{.Status}}'$'\t''{{.Label "com.docker.compose.project"}}'$'\t''{{.Label "com.docker.compose.project.working_dir"}}'
  fmt_stats='{{.Name}}'$'\t''{{.CPUPerc}}'$'\t''{{.MemUsage}}'$'\t''{{.MemPerc}}'
  fmt_insp='{{.Name}}'$'\t''{{.RestartCount}}'$'\t''{{if .State.Health}}{{.State.Health.Status}}{{end}}'

  ps="$(docker ps -a --format "$fmt_ps" 2>/dev/null | _console_tsv_json)"; [ -n "$ps" ] || ps='[]'
  stats="$(docker stats --no-stream --format "$fmt_stats" 2>/dev/null | _console_tsv_json)"; [ -n "$stats" ] || stats='[]'
  ids="$(docker ps -aq 2>/dev/null)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    insp="$(docker inspect --format "$fmt_insp" $ids 2>/dev/null | sed 's#^/##' | _console_tsv_json)"
  fi
  [ -n "${insp:-}" ] || insp='[]'
  projects="$(console_work_projects)"

  jq -c -n --argjson ps "$ps" --argjson stats "$stats" --argjson insp "$insp" --argjson projects "$projects" '
    ($stats | map({key: .[0], value: {cpu_pct: .[1], mem_used: (.[2] | split(" / ")[0]), mem_pct: .[3]}}) | from_entries) as $S
    | ($insp | map({key: .[0], value: {restarts: ((.[1] | tonumber?) // 0),
                                      health: (if (.[2] // "") == "" then null else .[2] end)}}) | from_entries) as $I
    | $ps | map(
        .[0] as $name | (.[4] // "") as $wd
        | {name: $name, state: .[1], status: .[2],
           compose_project: (if (.[3] // "") == "" then null else .[3] end),
           working_dir: (if $wd == "" then null else $wd end)}
        + ($S[$name] // {cpu_pct: null, mem_used: null, mem_pct: null})
        + ($I[$name] // {restarts: 0, health: null})
        | .project = ((($projects
              | map(select(.repo as $r | $wd != "" and (($wd + "/") | startswith($r + "/"))))
              | sort_by(.repo | length) | last | .name)) // .compose_project // $name))'
}
