load helpers

@test "hook output is always valid JSON or empty, exit 0" {
  setup_wt
  out="$(printf '{"cwd":"/tmp/none-%s"}' "$$" | "$WT_ROOT/bin/wt-session-hook"; echo "rc=$?")"
  [[ "$out" == *"rc=0" ]]
  body="${out%rc=*}"
  [ -z "$body" ] || echo "$body" | jq -e . >/dev/null
}
