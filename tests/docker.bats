load helpers
setup() { setup_wt; source "$WT_ROOT/lib/docker.sh"; export WT_DRY_RUN=1; }

@test "up emits compose up with project name" {
  run wt_docker_up /home/x/wt/app-x .docker/docker-compose.yml app-x
  [[ "$output" == *"docker compose -p app-x -f .docker/docker-compose.yml up -d --build"* ]]
}
@test "down emits compose down -v" {
  run wt_docker_down /home/x/wt/app-x .docker/docker-compose.yml app-x
  [[ "$output" == *"docker compose -p app-x -f .docker/docker-compose.yml down -v"* ]]
}
@test "status prints running container count" {
  run wt_docker_status app-x
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}
