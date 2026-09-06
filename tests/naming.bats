load helpers
setup() { setup_wt; source "$WT_ROOT/lib/naming.sh"; }

@test "slugify lowercases and hyphenates" {
  [ "$(wt_slugify 'GEL-123 Fix Header')" = "gel-123-fix-header" ]
}
@test "slugify collapses and trims separators" {
  [ "$(wt_slugify '  feature/Foo__Bar!! ')" = "feature-foo-bar" ]
}
@test "slugify caps length at 40" {
  out="$(wt_slugify "$(printf 'a%.0s' {1..80})")"; [ "${#out}" -le 40 ]
}
@test "project/domain/db/path/branch derive correctly" {
  [ "$(wt_project myprojekt-app gel-123)" = "myprojekt-app-gel-123" ]
  [ "$(wt_domain myprojekt-app gel-123)" = "myprojekt-app-gel-123.docker.test" ]
  [ "$(wt_db myprojekt-app gel-123)" = "myprojekt_app_gel_123" ]
  [ "$(wt_path myprojekt-app gel-123)" = "$HOME/wt/myprojekt-app-gel-123" ]
  [ "$(wt_branch feature gel-123)" = "feature/gel-123" ]
  [ "$(wt_branch hotfix gel-123)" = "hotfix/gel-123" ]
}
