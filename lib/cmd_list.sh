# shellcheck shell=bash
for m in ui naming registry docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_list() {
  if [ "${1:-}" = "--json" ]; then wt_reg_list; return; fi
  printf '%-30s %-34s %-22s %-6s\n' APP-SLUG DOMAIN BRANCH DOCKER
  wt_reg_list | jq -r '.[] | [.project, .domain, .branch] | @tsv' | while IFS=$'\t' read -r p d b; do
    printf '%-30s %-34s %-22s %-6s\n' "$p" "$d" "$b" "$(wt_docker_status "$p")"
  done
}
