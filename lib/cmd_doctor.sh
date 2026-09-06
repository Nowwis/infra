# shellcheck shell=bash
for m in ui registry docker; do source "$WT_ROOT/lib/$m.sh"; done
cmd_doctor() {
  local fix=0; [ "${1:-}" = "--fix" ] && fix=1
  local issues=0
  while IFS=$'\t' read -r project path; do
    if [ ! -d "$path" ]; then
      printf 'MISSING-DIR %s (%s)\n' "$project" "$path"; issues=$((issues+1))
      [ "$fix" = 1 ] && wt_reg_remove "$project"
    elif [ "$(wt_docker_status "$project")" = "0" ]; then
      printf 'NO-DOCKER %s\n' "$project"; issues=$((issues+1))
    fi
  done < <(wt_reg_list | jq -r '.[] | [.project, .path] | @tsv')
  # dirs under ~/wt not in registry -> orphan
  if [ -d "$HOME/wt" ]; then
    for d in "$HOME/wt"/*/; do [ -d "$d" ] || continue
      local name; name="$(basename "$d")"
      wt_reg_exists "$name" || { printf 'ORPHAN-DIR %s\n' "$name"; issues=$((issues+1)); }
    done
  fi
  [ "$issues" = 0 ] && ok "no anomalies" || true
}
