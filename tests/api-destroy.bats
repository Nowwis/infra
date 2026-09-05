load helpers
setup() {
  setup_wt
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/wt" <<'EOF'
#!/bin/bash
if [ "$1" = list ]; then echo '[{"app":"myapp","slug":"t1","project":"myapp-t1"}]'; exit 0; fi
if [ "$1" = destroy ]; then echo "destroyed $2 $3 $4"; exit 0; fi
EOF
  chmod +x "$BIN/wt"; export WT_DASH_WT="$BIN/wt"
  command -v php >/dev/null || skip "php not installed"
}
@test "destroy of a known project calls wt destroy" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/destroy.php"; echo wt_api_destroy("myapp-t1");'
  echo "$output" | jq -e '.ok==true' >/dev/null
  [[ "$output" == *"destroyed myapp t1 --yes"* ]]
}
@test "destroy of an unknown project is refused, no wt destroy" {
  run php -r 'require getenv("WT_ROOT")."/dashboard/server/destroy.php"; echo wt_api_destroy("evil-proj");'
  echo "$output" | jq -e '.ok==false' >/dev/null
  [[ "$output" != *"destroyed"* ]]
}
