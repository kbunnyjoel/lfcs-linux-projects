  rotate)
    # Options: --dest DIR [--keep-full N] [--keep-inc N] [--max-age-days N]
    keep_full=""; keep_inc=""; max_age=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dest) dest_root="$2"; shift 2;;
        --keep-full) keep_full="$2"; shift 2;;
        --keep-inc) keep_inc="$2"; shift 2;;
        --max-age-days) max_age="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) die "unknown option: $1";;
      esac
    done

    [[ -n "$dest_root" ]] || die "--dest required"
    [[ -d "$dest_root" ]] || die "destination root '$dest_root' not found or not a directory"

    outputs_dir="${ROOT_DIR}/outputs"
    mkdir -p "$outputs_dir"

    # Collect metadata from outputs/*/summary.json
    mapfile -t summaries < <(find "$outputs_dir" -mindepth 2 -maxdepth 2 -type f -name summary.json -print 2>/dev/null)

    # Nothing to do
    if [[ ${#summaries[@]} -eq 0 ]]; then
      ok "rotate: nothing to prune"
      exit 0
    fi

    # Build a TSV: id\tlevel\tbase_id\tartifact\tmtime\n
    tmpmeta=$(mktemp)
    >"$tmpmeta"
    for s in "${summaries[@]}"; do
      d=$(dirname -- "$s")
      id=$(basename -- "$d")
      # Extract fields with jq (fallback to empty on failure)
      level=$(jq -r '(.level // "")' "$s" 2>/dev/null || echo "")
      base_id=$(jq -r '(.base_id // "")' "$s" 2>/dev/null || echo "")
      artifact=$(jq -r '(.artifact // "")' "$s" 2>/dev/null || echo "")
      # mtime in epoch seconds for age decisions (use summary.json mtime)
      if stat -c %Y "$s" >/dev/null 2>&1; then mtime=$(stat -c %Y "$s");
      elif stat -f %m "$s" >/dev/null 2>&1; then mtime=$(stat -f %m "$s");
      else mtime=$(date +%s); fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$level" "$base_id" "$artifact" "$mtime" >>"$tmpmeta"
    done

    # Helper: sort by id (timestamp prefix) descending
    sort_desc() { sort -r; }

    # Determine fulls sorted newest->oldest
    mapfile -t full_ids < <(awk -F '\t' '$2=="full"{print $1}' "$tmpmeta" | sort_desc)

    # Mark sets to delete
    tmpdel=$(mktemp); >"$tmpdel"

    # Rule 1: keep last N fulls
    if [[ -n "$keep_full" && "$keep_full" =~ ^[0-9]+$ ]]; then
      # fulls beyond N are candidates along with their increments/diffs
      if [[ ${#full_ids[@]} -gt $keep_full ]]; then
        for ((i=keep_full;i<${#full_ids[@]};i++)); do
          oldfull="${full_ids[$i]}"
          # delete the full itself
          awk -v id="$oldfull" -F '\t' '$1==id{print $1}' "$tmpmeta" >>"$tmpdel"
          # delete entries whose base_id starts with this full id (inc/diff linked to it)
          awk -v id="$oldfull" -F '\t' '$3!="" && index($3,id)==1{print $1}' "$tmpmeta" >>"$tmpdel"
        done
      fi
    fi

    # Rule 2: max age
    if [[ -n "$max_age" && "$max_age" =~ ^[0-9]+$ ]]; then
      now=$(date +%s)
      cutoff=$(( now - max_age*24*3600 ))
      awk -v c="$cutoff" -F '\t' '$5!="" && $5<c {print $1}' "$tmpmeta" >>"$tmpdel"
    fi

    # Rule 3: keep-inc per full (keep only the newest K increments between two fulls)
    if [[ -n "$keep_inc" && "$keep_inc" =~ ^[0-9]+$ ]]; then
      for fid in "${full_ids[@]}"; do
        # increments/diffs tied to this full (by base_id prefix)
        mapfile -t incs < <(awk -v id="$fid" -F '\t' '$2!="full" && index($3,id)==1 {print $1}' "$tmpmeta" | sort_desc)
        if [[ ${#incs[@]} -gt $keep_inc ]]; then
          for ((i=keep_inc;i<${#incs[@]};i++)); do
            echo "${incs[$i]}" >>"$tmpdel"
          done
        fi
      done
    fi

    # Unique ids to delete
    mapfile -t del_ids < <(sort -u "$tmpdel")

    # Perform deletions: remove outputs/<id> and artifact path/file/dir if present
    deleted=0
    for did in "${del_ids[@]}"; do
      # get artifact for this id
      art=$(awk -v id="$did" -F '\t' '$1==id{print $4}' "$tmpmeta" | head -n1)
      outdir="${outputs_dir}/$did"
      # Remove artifact if it exists (file or directory)
      if [[ -n "$art" ]]; then
        if [[ -d "$art" ]]; then rm -rf -- "$art" 2>/dev/null || true; fi
        if [[ -f "$art" ]]; then rm -f -- "$art" 2>/dev/null || true; fi
      fi
      # Remove outputs metadata dir
      if [[ -d "$outdir" ]]; then rm -rf -- "$outdir" 2>/dev/null || true; fi
      deleted=$((deleted+1))
    done

    rm -f "$tmpmeta" "$tmpdel"
    ok "rotate: pruned $deleted item(s)"
    exit 0
    ;;
