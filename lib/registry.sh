# shellcheck shell=bash
source "${WT_ROOT}/lib/ui.sh"
_wt_reg_file() { printf '%s/registry.json' "$WT_STATE"; }
_wt_reg_init() { mkdir -p "$WT_STATE"; [ -f "$(_wt_reg_file)" ] || echo '[]' > "$(_wt_reg_file)"; }
wt_reg_add() {
  _wt_reg_init; local f; f="$(_wt_reg_file)"
  local tmp; tmp="$(mktemp)"
  jq --argjson e "$1" 'map(select(.project != ($e.project))) + [$e]' "$f" > "$tmp" && mv "$tmp" "$f"
}
wt_reg_remove() {
  _wt_reg_init; local f; f="$(_wt_reg_file)"; local tmp; tmp="$(mktemp)"
  jq --arg p "$1" 'map(select(.project != $p))' "$f" > "$tmp" && mv "$tmp" "$f"
}
wt_reg_exists() { _wt_reg_init; jq -e --arg p "$1" 'any(.project == $p)' "$(_wt_reg_file)" >/dev/null; }
wt_reg_get()    { _wt_reg_init; jq -c --arg p "$1" '.[] | select(.project == $p)' "$(_wt_reg_file)"; }
wt_reg_list()   { _wt_reg_init; cat "$(_wt_reg_file)"; }
