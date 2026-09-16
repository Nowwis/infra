# shellcheck shell=bash
# Section docker_df : occupation disque de Docker (images, conteneurs, volumes, cache).
# `docker system df` prend une dizaine de secondes : cette section tourne en tâche de fond.

section_docker_df() {
  docker system df --format '{{json .}}' 2>/dev/null \
    | jq -s -c 'map({type: .Type, size: .Size, reclaimable: .Reclaimable,
                     total: .TotalCount, active: .Active})' 2>/dev/null
}
