load helpers
setup() { setup_wt; P="$WT_ROOT/dashboard/public"; }
@test "index.html loads app.js and style.css and has section containers" {
  [ -f "$P/index.html" ] && [ -f "$P/app.js" ] && [ -f "$P/style.css" ]
  grep -q 'app.js' "$P/index.html"; grep -q 'style.css' "$P/index.html"
  for id in system docker worktrees sessions disk; do grep -q "id=\"$id\"" "$P/index.html"; done
}
@test "app.js polls /api/metrics and wires destroy; index exposes CSV export + search" {
  grep -q '/api/metrics' "$P/app.js"
  grep -q '/destroy' "$P/app.js"
  grep -qi 'setInterval\|setTimeout' "$P/app.js"
  grep -q 'metrics.csv' "$P/index.html"
  grep -q 'id="q"' "$P/index.html"
}
@test "no external CDN dependency" {
  ! grep -qiE 'https?://[^"]+\.(js|css)' "$P/index.html"
}
