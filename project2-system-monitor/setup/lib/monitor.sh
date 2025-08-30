#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

collect_cpu() {
  local usage=0 cores
  case "$(uname -s)" in
    Linux)
      if command -v mpstat >/dev/null 2>&1; then
        usage="$(mpstat 1 1 | awk '/Average/ && $NF ~ /[0-9.]+/ { printf("%.0f\n", 100 - $NF) }')"
      else
        local c l
        c="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
        l="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
        usage="$(awk -v l="$l" -v c="$c" 'BEGIN{printf("%.0f\n", (c>0? (l/c)*100 : 0))}')"
      fi
      ;;
    Darwin)
      # Robustly parse idle percentage from 'top' and compute usage = 100 - idle.
      # Example: "CPU usage: 25.45% user, 13.76% sys, 60.77% idle"
      local idle usage_raw
      idle="$(top -l 1 -n 0 | awk '/CPU usage/ { for (i=1;i<=NF;i++) if ($i ~ /idle/) { v=$(i-1); gsub("%","",v); print v; exit } }')"
      # Fallback: grep the "<num>% idle" token and strip the percent
      if [[ -z "$idle" ]]; then
        idle="$(top -l 1 -n 0 | grep -Eo '[0-9]+(\.[0-9]+)?% idle' | awk '{gsub("%","",$1); print $1}' | head -1)"
      fi
      # If still empty, assume 0 idle (worst case) to avoid NaN/unbound
      if [[ -z "$idle" ]]; then idle=0; fi
      usage_raw="$(awk -v i="$idle" 'BEGIN{u=100-i; if(u<0)u=0; if(u>100)u=100; print u}')"
      usage="$(printf "%.0f" "$usage_raw")"
      ;;
    *) usage=0 ;;
  esac
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  echo "CPU_USAGE=${usage}"
  echo "CPU_CORES=${cores}"
}

collect_mem() {
  case "$(uname -s)" in
    Linux)
      awk '
        $1=="MemTotal:"{total=$2/1024}
        $1=="MemAvailable:"{avail=$2/1024}
        END{
          used=total-avail
          printf("MEM_TOTAL_MB=%.0f\nMEM_USED_MB=%.0f\nMEM_FREE_MB=%.0f\n", total, used, avail)
        }
      ' /proc/meminfo
      ;;
    Darwin)
      # Approximate using vm_stat (MB)
      local ps free active wired speculative used total
      ps="$(vm_stat 2>/dev/null | awk '/page size of/{print $8}')"
      free="$(vm_stat 2>/dev/null | awk '/Pages free/{gsub("\\.","",$3); print $3}')"
      active="$(vm_stat 2>/dev/null | awk '/Pages active/{gsub("\\.","",$3); print $3}')"
      wired="$(vm_stat 2>/dev/null | awk '/Pages wired down/{gsub("\\.","",$4); print $4}')"
      speculative="$(vm_stat 2>/dev/null | awk '/Pages speculative/{gsub("\\.","",$3); print $3}')"
      used=$(( (active + wired + speculative) * ps / 1048576 ))
      total="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
      total=$(( total / 1048576 ))
      free=$(( total - used ))
      echo "MEM_TOTAL_MB=${total}"
      echo "MEM_USED_MB=${used}"
      echo "MEM_FREE_MB=${free}"
      ;;
  esac
}

collect_disk() {
  # If DISK_MOUNTS is unset or empty, report only root fs as before
  if [[ -z "${DISK_MOUNTS:-}" ]]; then
    df -h / | awk 'NR==2{print "DISK_FS="$1"\nDISK_USED="int($5)"\nDISK_SIZE="$2}'
    return
  fi
  # Otherwise, iterate over comma-separated list
  local mounts="$DISK_MOUNTS"
  local IFS=',' mnt token
  for mnt in $mounts; do
    # Remove leading/trailing whitespace
    mnt="$(echo "$mnt" | sed 's/^ *//;s/ *$//')"
    # Sanitize token: replace non-alnum with _, collapse _, uppercase
    token="$(echo "$mnt" | sed 's/[^[:alnum:]]/_/g' | tr '[:lower:]' '[:upper:]' | sed 's/__*/_/g; s/^_//; s/_$//')"
    # Find the matching line in df -h output
    # shellcheck disable=SC2016
    df -h "$mnt" 2>/dev/null | awk -v t="$token" 'NR==2{printf("DISK_%s_FS=%s\nDISK_%s_USED=%d\nDISK_%s_SIZE=%s\n", t,$1,t,int($5),t,$2)}'
  done
}

collect_load() {
  case "$(uname -s)" in
    Linux) awk '{printf("LOAD_1=%s\nLOAD_5=%s\nLOAD_15=%s\n",$1,$2,$3)}' /proc/loadavg ;;
    Darwin) sysctl -n vm.loadavg | awk -F'[ {}]' '{print "LOAD_1="$3"\nLOAD_5="$4"\nLOAD_15="$5}' ;;
  esac
}

check_process() {
  local name="$1"
  if pgrep -x "$name" >/dev/null 2>&1; then
    echo "PROC_${name}_RUNNING=1"
  else
    echo "PROC_${name}_RUNNING=0"
  fi
}

collect_top_procs() {
  # Only run if explicitly enabled (case-insensitive true/1/yes)
  local enable="${TOP_PROCS_ENABLE:-false}"
  case "$enable" in
    true|TRUE|True|1|yes|YES) ;;
    *) return 0 ;;
  esac

  # Add a timestamp marker for correlation
  echo "TOP_PROCS_TS=$(timestamp)"

  # Determine N with a safe upper bound
  local N="${TOP_PROCS:-5}"
  [[ -z "$N" || "$N" -le 0 ]] && N=5
  [[ "$N" -gt 10 ]] && N=10   # cap to 10 to avoid excessive load

  # Optional ignore list (comma-separated). We won't modify env files; just honor if set.
  local IGNORE_RAW IGNORE_RE
  IGNORE_RAW="${TOP_PROCS_IGNORE:-}"
  if [[ -n "$IGNORE_RAW" ]]; then
    # Build a case-insensitive regex by lowercasing and escaping special chars; join by |
    IGNORE_RE="$(echo "$IGNORE_RAW" | tr '[:upper:]' '[:lower:]' | \
      sed 's/[][().^$*+?{}|\\\/-]/\\\\&/g; s/,/|/g')"
  else
    IGNORE_RE=""
  fi

  # Helper: emit ranked lines from ps output
  _emit_ranked() {
    # $1 = which list label (CPU or MEM)
    # reads ps lines on stdin
    local label="$1"; local count=0
    awk -v n="$N" -v ign_re="$IGNORE_RE" -v label="$label" '
      BEGIN { IGNORECASE=1 }
      NR==1 { next } # skip header if present
      {
        pid=$1; pcpu=$2; pmem=$3; rss_kb=$4; vsz_kb=$5; $1=$2=$3=$4=$5=""; sub(/^ */,"",$0); cmd=$0;
        # If command missing (comm column), use "unknown"
        if (cmd=="") cmd="unknown"
        # Apply ignore filter if provided
        low=cmd; for(i=1;i<=length(low);i++){ c=substr(low,i,1); if(c>="A" && c<="Z") low=substr(low,1,i-1) tolower(c) substr(low,i+1) }
        if (ign_re!="" && low ~ ("(" ign_re ")")) next
        # Sanitize commas so our KV stays parseable; keep spaces (readability)
        gsub(",",".",cmd)
        # Truncate overly long command
        if (length(cmd) > 80) { cmd=substr(cmd,1,77) "..." }
        count++
        printf("TOP_%s_%d=pid:%s,pcpu:%s,pmem:%s,rss_kb:%s,vsz_kb:%s,cmd:%s\n", label, count, pid, pcpu, pmem, rss_kb, vsz_kb, cmd)
        if (count>=n) exit
      }
    '
  }

  case "$(uname -s)" in
    Linux)
      # By CPU
      ps -eo pid,pcpu,pmem,rss,vsz,comm --sort=-pcpu 2>/dev/null | _emit_ranked CPU
      # By MEM
      ps -eo pid,pcpu,pmem,rss,vsz,comm --sort=-pmem 2>/dev/null | _emit_ranked MEM
      ;;
    Darwin)
      # By CPU (ps -r sorts by CPU desc on macOS). Include rss/vsz.
      ps -Ao pid,pcpu,pmem,rss,vsz,comm -r 2>/dev/null | _emit_ranked CPU
      # By MEM (sort by pmem desc)
      ps -Ao pid,pcpu,pmem,rss,vsz,comm 2>/dev/null | sed 1d | sort -k3,3nr | \
        awk 'BEGIN{print "PID %CPU %MEM RSS VSZ COMMAND"} {print}' | _emit_ranked MEM
      ;;
    *)
      # Unsupported OS; skip silently
      ;;
  esac
}
