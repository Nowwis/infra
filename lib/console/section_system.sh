# shellcheck shell=bash
# Section system : mémoire, swap, charge, pression (PSI), compteur OOM.
# `journalctl -k` étant interdit sans le groupe adm, les kills OOM se lisent dans vmstat.

_console_meminfo() { awk -v k="$1:" '$1 == k {print $2; exit}' "$CONSOLE_PROC/meminfo" 2>/dev/null; }

_console_psi() { # ressource ligne(some|full) clé(avg10|avg60)
  awk -v l="$2" -v a="$3" '$1 == l {
      for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == a) print kv[2] }
    }' "$CONSOLE_PROC/pressure/$1" 2>/dev/null
}

section_system() {
  local mt ma st sf load ncpu oom cpu10 mem60 memfull60 io60
  mt="$(_console_meminfo MemTotal)"; ma="$(_console_meminfo MemAvailable)"
  st="$(_console_meminfo SwapTotal)"; sf="$(_console_meminfo SwapFree)"
  load="$(awk '{print $1}' "$CONSOLE_PROC/loadavg" 2>/dev/null)"
  ncpu="$(nproc 2>/dev/null)"
  oom="$(awk '/^oom_kill /{print $2}' "$CONSOLE_PROC/vmstat" 2>/dev/null)"
  cpu10="$(_console_psi cpu some avg10)"
  mem60="$(_console_psi memory some avg60)"
  memfull60="$(_console_psi memory full avg60)"
  io60="$(_console_psi io some avg60)"

  jq -c -n --argjson mt "${mt:-0}" --argjson ma "${ma:-0}" --argjson st "${st:-0}" --argjson sf "${sf:-0}" \
     --argjson load "${load:-0}" --argjson ncpu "${ncpu:-0}" --argjson oom "${oom:-0}" \
     --argjson cpu10 "${cpu10:-0}" --argjson mem60 "${mem60:-0}" \
     --argjson memfull60 "${memfull60:-0}" --argjson io60 "${io60:-0}" '
    {mem_total_kb: $mt, mem_avail_kb: $ma,
     swap_total_kb: $st, swap_used_kb: ($st - $sf),
     load1: $load, ncpu: $ncpu,
     psi: {cpu_some_avg10: $cpu10, mem_some_avg60: $mem60,
           mem_full_avg60: $memfull60, io_some_avg60: $io60},
     oom_kill_total: $oom}'
}
