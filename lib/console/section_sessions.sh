# shellcheck shell=bash
# Section sessions : sessions Claude vivantes (source : ~/.claude/sessions/*.json),
# RAM de leur arbre de processus, serveurs MCP rattachés, ticket work tenu,
# et serveurs MCP orphelins (hors de l'arbre de toute session vivante).
# Une session est vivante si son pid figure dans la liste des processus.

_console_sessions_files() {
  local f
  for f in "$CONSOLE_SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -c 'select(.pid != null and .sessionId != null)' "$f" 2>/dev/null
  done | jq -s -c '.'
}

# Verrous work par projet : [{project, owner, ticket}]
_console_work_tickets() {
  local name repo f
  console_work_projects | jq -r '.[] | [.name, .repo] | @tsv' | while IFS=$'\t' read -r name repo; do
    f="$repo/.git/claude-work.json"
    [ -f "$f" ] || continue
    jq -c --arg n "$name" '{project: $n, owner: (.owner_session // null),
                            ticket: (if .state == "active" then .ticket else null end)}' "$f" 2>/dev/null
  done | jq -s -c '.'
}

section_sessions() {
  local procs sessions projects tickets events
  procs="$(ps -eo pid=,ppid=,rss=,args= 2>/dev/null \
    | awk '{pid=$1; ppid=$2; rss=$3; $1=$2=$3=""; sub(/^ +/, ""); printf "%s\t%s\t%s\t%s\n", pid, ppid, rss, $0}' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") |
        {pid: (.[0] | tonumber), ppid: (.[1] | tonumber), rss: (.[2] | tonumber), args: .[3]})' 2>/dev/null)"
  [ -n "$procs" ] || procs='[]'
  sessions="$(_console_sessions_files)"; [ -n "$sessions" ] || sessions='[]'
  projects="$(console_work_projects)"
  tickets="$(_console_work_tickets)"; [ -n "$tickets" ] || tickets='[]'
  events="$(console_journal_events)"; [ -n "$events" ] || events='[]'

  jq -c -n --argjson procs "$procs" --argjson sessions "$sessions" --argjson projects "$projects" \
     --argjson tickets "$tickets" --argjson events "$events" \
     --argjson now "$(date +%s)" --arg home "$HOME" '
    def descend($children; $root): [$root] + ((($children[$root | tostring]) // []) | map(descend($children; .)) | flatten);

    ($procs | map(.pid)) as $pids
    | ($procs | group_by(.ppid) | map({key: (.[0].ppid | tostring), value: map(.pid)}) | from_entries) as $children
    | ($sessions | map(select(.pid as $p | ($pids | index($p)) != null))) as $live
    | ($live | map(descend($children; .pid)) | flatten) as $in_trees
    | {items: ($live | map(
        . as $s
        | descend($children; .pid) as $tree
        | ($procs | map(select(.pid as $p | ($tree | index($p)) != null))) as $tp
        | ($s.cwd // "") as $cwd
        # Statut : dernier evenement de la session dans le journal (pas d apostrophe ici,
        # le programme jq est entre guillemets simples).
        | ($events | map(select(.session == $s.sessionId))) as $se
        | ($se | last) as $last
        | ($se | map(select(.event == "guard.block")) | last) as $block
        | {session_id: $s.sessionId, pid: $s.pid, name: ($s.name // null), kind: ($s.kind // null),
           status: (if $last == null then "unknown"
                    elif $last.event == "Notification" then "waiting"
                    elif $last.event == "Stop" then "idle"
                    elif $last.event == "PreToolUse" then "executing"
                    else "working" end),
           status_detail: (if $last == null then null
                           elif ($last.summary // "") == "" then null
                           else $last.summary end),
           status_since_s: (if $last == null or ($last.ts // "") == "" then null
                            else ($now - ($last.ts | fromdateiso8601)) end),
           last_block: (if $block == null then null else ($block.summary // null) end),
           cwd: ($s.cwd // null),
           tmux: (if $s.tmux then ($s.tmux | split(":")[0]) else null end),
           started_at: ($s.startedAt // null),
           age_s: (if $s.startedAt then ($now - (($s.startedAt / 1000) | floor)) else null end),
           rss_kb: (($tp | map(.rss) | add) // 0),
           system: ($cwd | startswith($home + "/.claude-mem")),
           project: (($projects
             | map(select(.repo as $r | $cwd != "" and (($cwd + "/") | startswith($r + "/"))))
             | sort_by(.repo | length) | last | .name) // null),
           mcp: ($tp | map(select(.args | test("mcp"; "i"))) | map(.args))}
        | . as $item
        | .ticket = (($tickets
             | map(select(.project == $item.project and .owner == $item.session_id))
             | first | .ticket) // null))),
       mcp_orphans: ($procs
         | map(select((.args | test("mcp"; "i")) and ((.pid as $p | $in_trees | index($p)) == null)))
         | group_by(.args)
         | map({command: .[0].args, count: length, rss_kb: (map(.rss) | add)}))}'
}
