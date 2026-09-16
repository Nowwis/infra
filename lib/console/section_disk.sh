# shellcheck shell=bash
# Section disk : un objet par point de montage, tailles en Ko, pourcentage numérique.

section_disk() {
  df -P -k 2>/dev/null \
    | awk 'NR > 1 {printf "%s\t%s\t%s\t%s\t%s\n", $6, $2, $3, $4, $5}' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") |
        {mount: .[0],
         size: (try (.[1] | tonumber) catch null),
         used: (try (.[2] | tonumber) catch null),
         avail: (try (.[3] | tonumber) catch null),
         use_pct: (try (.[4] | rtrimstr("%") | tonumber) catch null)})' 2>/dev/null
}
