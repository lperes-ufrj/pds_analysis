#!/usr/bin/env bash
# Rename pipeline outputs from the hashed sample tags of the previous scheme
# to the readable tags, for the given cut sets:
#
#   default_coinc_w10_a0_r_292kV_888e6582        (selection and coincidence)
#   -> coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV_aux500_full10000   (selection)
#   -> coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV                     (coincidence)
#
# Nothing is rerun: folders, the files in them whose names carry the tag, and
# the settings snapshots are renamed or rewritten, keeping time stamps, so
# the pipeline finds them cached. Even older prefixes (c_m8_, c_low_, s_)
# are recognized as well.
#
# Usage:
#   pipeline/migrate_tags.sh [--dry-run] [CUTSET ...]
#
#   CUTSET     pipeline/cutsets/NAME.env or a path to a .env file (default:
#              every cut set in pipeline/cutsets/). A deleted cut set can be
#              migrated from git, e.g.
#                git show d44b0bc:pipeline/cutsets/single_m8.env > /tmp/single_m8.env
#                pipeline/migrate_tags.sh /tmp/single_m8.env
#   --dry-run  print what would change, change nothing
#
# A selection folder is migrated only when its cut flow was made with the
# cut set's waveform cuts and intervals (its pipeline_selection_settings.txt
# says so); the old tag's hash already pins the rest. Fits in
# $PDS_OUTPUT/pipeline/*/*/ made on a migrated sample get the new tag in
# sample.txt and in their copy of the cut flow; they keep their cut-set
# folder name.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
OUTPUT_ROOT=${PDS_OUTPUT:-$REPO_DIR/output}
SELECTED=$REPO_DIR/coincidence/selected_waveforms
SAVED=$REPO_DIR/coincidence/saved_coincidences

DRY_RUN=0
CUTSETS=()
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option $arg" >&2; exit 2 ;;
        *) CUTSETS+=("$arg") ;;
    esac
done
((${#CUTSETS[@]})) || CUTSETS=("$SCRIPT_DIR"/cutsets/*.env)

act() { printf '  %s\n' "$*"; ((DRY_RUN)) || "$@"; }

# replace OLD by NEW inside a text file, keeping its time stamp
rewrite() {  # FILE OLD NEW
    grep -qF -- "$2" "$1" || return 0
    echo "  edit $1"
    ((DRY_RUN)) && return 0
    local tmp
    tmp=$(mktemp)
    cp -p "$1" "$tmp"
    sed "s|$2|$3|g" "$tmp" > "$1"
    touch -r "$tmp" "$1"
    rm -f "$tmp"
}

# write TEXT to FILE with the time stamp of REFERENCE (the fit and light
# yield compare their markers against the selection snapshot's time)
replace_with() {  # FILE TEXT REFERENCE
    echo "  write $1"
    ((DRY_RUN)) && return 0
    local stamp
    stamp=$(mktemp)
    touch -r "$3" "$stamp"
    printf '%s\n' "$2" > "$1"
    touch -r "$stamp" "$1"
    rm -f "$stamp"
}

rename_files() {  # DIR OLD NEW: files whose names carry OLD
    local file
    for file in "$1"/*"$2"*; do
        [[ -e $file ]] || continue
        act mv -- "$file" "$1/$(basename "$file" | sed "s|$2|$3|g")"
    done
}

# the legacy tag and its even older spellings
candidates() {
    echo "$1"
    case $1 in
        default_coinc_*) echo "c_m8_${1#default_coinc_}" ;;
        inverse_coinc_*) echo "c_low_${1#inverse_coinc_}" ;;
        no_coinc_*)      echo "s_${1#no_coinc_}" ;;
    esac
}

# an old selection snapshot (tag on line 1) matches the new one (tag and
# rate line on lines 1-2) when the rest is equal
same_cuts() {  # OLD_SNAPSHOT_FILE NEW_SNAPSHOT_TEXT
    [[ $(tail -n +2 "$1") == "$(tail -n +3 <<< "$2")" ]]
}

migrated=0
for cutset in "${CUTSETS[@]}"; do
    pipeline() { "$SCRIPT_DIR/run_pipeline.sh" "$cutset" "$@"; }
    legacy=$(pipeline --print legacy-tag)
    sample=$(pipeline --print tag)
    coinc=$(pipeline --print coinc-tag)
    selection_settings=$(pipeline --print selection-settings)
    coinc_settings=$(pipeline --print coinc-settings)
    echo "== $(basename "$cutset" .env): $legacy"
    echo "   -> selection $sample${coinc:+, coincidence $coinc}"

    for old in $(candidates "$legacy"); do
        # ------------------------------------------------------ selection
        dir=$SELECTED/$old
        if [[ -d $dir ]]; then
            snapshot=$dir/pipeline_selection_settings.txt
            if [[ -e $SELECTED/$sample ]]; then
                echo "  skipped $dir: $SELECTED/$sample already exists"
            elif [[ ! -f $snapshot ]]; then
                echo "  skipped $dir: no pipeline_selection_settings.txt"
            elif ! same_cuts "$snapshot" "$selection_settings"; then
                echo "  skipped $dir: selected with other waveform cuts or intervals than this cut set"
            else
                rename_files "$dir" "$old" "$sample"
                [[ -f $dir/sample.txt ]] && rewrite "$dir/sample.txt" "$old" "$sample"
                replace_with "$snapshot" "$selection_settings" "$snapshot"
                act mv -- "$dir" "$SELECTED/$sample"
                migrated=$((migrated + 1))
            fi
        fi

        # ---------------------------------------------------- coincidence
        dir=$SAVED/$old
        if [[ -n $coinc && -d $dir ]]; then
            if [[ -e $SAVED/$coinc ]]; then
                echo "  skipped $dir: $SAVED/$coinc already exists"
            else
                rename_files "$dir" "$old" "$coinc"
                snapshot=$dir/pipeline_coincidence_settings.txt
                reference=$snapshot
                [[ -f $reference ]] || reference=$dir
                replace_with "$snapshot" "$coinc_settings" "$reference"
                act mv -- "$dir" "$SAVED/$coinc"
                migrated=$((migrated + 1))
            fi
        fi

        # ----------------------------------------------------------- fits
        for info in "$OUTPUT_ROOT"/pipeline/*/*/sample.txt; do
            [[ -f $info ]] || continue
            [[ $(sed -n 's/^sample tag : //p' "$info") == "$old" ]] || continue
            fit=$(dirname "$info")
            snapshot=$fit/selection/pipeline_selection_settings.txt
            if [[ -f $snapshot ]] && ! same_cuts "$snapshot" "$selection_settings"; then
                continue  # a fit of another cut set sharing the old tag
            fi
            echo "  fit $fit"
            rewrite "$info" "$old" "$sample"
            if [[ -d $fit/selection ]]; then
                rename_files "$fit/selection" "$old" "$sample"
                [[ -f $snapshot ]] && replace_with "$snapshot" "$selection_settings" "$snapshot"
            fi
        done
    done
done

echo "Migrated $migrated folder(s)$( ((DRY_RUN)) && echo ' (dry run: nothing changed)')."
