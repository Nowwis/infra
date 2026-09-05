load helpers
setup() { setup_wt; source "$WT_ROOT/lib/registry.sh"; }

@test "add then exists then get" {
  wt_reg_add '{"project":"app-x","app":"app","slug":"x","db":"app_x"}'
  run wt_reg_exists app-x; [ "$status" -eq 0 ]
  [ "$(wt_reg_get app-x | jq -r .db)" = "app_x" ]
}
@test "list returns array; remove drops entry" {
  wt_reg_add '{"project":"app-x","app":"app","slug":"x"}'
  wt_reg_add '{"project":"app-y","app":"app","slug":"y"}'
  [ "$(wt_reg_list | jq 'length')" = "2" ]
  wt_reg_remove app-x
  [ "$(wt_reg_list | jq 'length')" = "1" ]
  run wt_reg_exists app-x; [ "$status" -ne 0 ]
}
