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

@test "index.html : panneau Activité présent" {
  grep -q 'id="activity"' "$P/index.html"
  grep -qi 'activité' "$P/index.html"
}

@test "app.js : rend le flux d'activité et le statut des sessions" {
  grep -q 'renderActivity' "$P/app.js"
  grep -q "dataOf(snap, 'activity')" "$P/app.js"
  grep -qE "executing|waiting|idle" "$P/app.js"
  grep -q 'last_block' "$P/app.js"
}

@test "le flux d'activité reste en lecture seule" {
  run grep -qiE 'innerHTML|method: *.POST' "$P/app.js"
  [ "$status" -eq 1 ]
}
