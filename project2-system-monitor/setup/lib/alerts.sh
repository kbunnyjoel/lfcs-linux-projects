#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

assert_threshold() {
  local op="$2" limit="$3" value="$4"
  awk -v v="$value" -v o="$op" -v l="$limit" '
    function cmp(a,op,b){
      if(op==">") return (a>b);
      if(op==">=") return (a>=b);
      if(op=="<") return (a<b);
      if(op=="<=") return (a<=b);
      if(op=="==") return (a==b);
      if(op!="!=" && op!=">" && op!=">=" && op!="<" && op!="<=" && op!="==") exit 2;
      return (a!=b);
    }
    BEGIN{ if(cmp(v,o,l)) exit 0; else exit 1 }
  '
}

evaluate_alerts() {
  local kvfile="$1"
  local cpu disk_pct total used pct bad=0

  cpu="$(awk -F= '$1=="CPU_USAGE"{print $2}' "$kvfile" 2>/dev/null || echo 0)"
  disk_pct="$(awk -F= '$1=="DISK_USED"{print $2}' "$kvfile" 2>/dev/null || echo 0)"
  total="$(awk -F= '$1=="MEM_TOTAL_MB"{print $2}' "$kvfile" 2>/dev/null || echo 0)"
  used="$(awk -F= '$1=="MEM_USED_MB"{print $2}' "$kvfile" 2>/dev/null || echo 0)"
  if [[ "$total" -gt 0 ]]; then pct=$(( used * 100 / total )); else pct=0; fi

  if ! assert_threshold "CPU_USAGE" "<" "${CPU_WARN}" "${cpu}"; then warn "CPU high: ${cpu}% (limit ${CPU_WARN}%)"; log_warn "CPU high: ${cpu}% (limit ${CPU_WARN}%)"; bad=1; fi
  if ! assert_threshold "MEM_PCT"  "<" "${MEM_WARN}" "${pct}"; then  warn "MEM high: ${pct}% (limit ${MEM_WARN}%)";   log_warn "MEM high: ${pct}% (limit ${MEM_WARN}%)"; bad=1; fi
  if ! assert_threshold "DISK_PCT" "<" "${DISK_WARN}" "${disk_pct}"; then warn "DISK high: ${disk_pct}% (limit ${DISK_WARN}%)"; log_warn "DISK high: ${disk_pct}% (limit ${DISK_WARN}%)"; bad=1; fi

  return "$bad"
}
