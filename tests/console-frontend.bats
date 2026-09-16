load helpers
setup() { setup_infra; P="$INFRA_ROOT/console/public"; }

@test "index.html : sections attendues, CSS et JS locaux" {
  [ -f "$P/index.html" ] && [ -f "$P/app.js" ] && [ -f "$P/style.css" ]
  grep -q 'app.js' "$P/index.html"
  grep -q 'style.css' "$P/index.html"
  for id in system diagnostics projects sessions docker disk; do
    grep -q "id=\"$id\"" "$P/index.html"
  done
}

@test "app.js interroge /api/snapshot, rafraîchit et signale les données périmées" {
  grep -q '/api/snapshot' "$P/app.js"
  grep -qi 'setInterval' "$P/app.js"
  grep -q 'stale' "$P/app.js"
  grep -q 'snapshot.csv' "$P/index.html"
  grep -q 'id="q"' "$P/index.html"
}

@test "aucune écriture : ni action destructive, ni innerHTML, ni worktree" {
  run grep -qiE 'innerHTML|/destroy|worktree|method: *.POST' "$P/app.js" "$P/index.html" "$P/style.css"
  [ "$status" -eq 1 ]
}

@test "aucune dépendance externe" {
  ! grep -qiE 'https?://[^"]+\.(js|css)' "$P/index.html"
}
