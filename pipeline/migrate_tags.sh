#!/usr/bin/env bash
# Rename pipeline outputs from the old sample-tag prefixes to the new ones:
#
#   c_m8_...   ->  default_coinc_...   (TRIGGER=m8   is now default_coinc)
#   c_low_...  ->  inverse_coinc_...   (TRIGGER=low  is now inverse_coinc)
#   s_...      ->  no_coinc_...        (MODE=single  is now TRIGGER=no_coinc)
#
# The hash at the end of each tag is unchanged, so renamed folders are found
# and reused by pipeline/run_pipeline.sh without rerunning anything.
#
# Usage:
#   pipeline/migrate_tags.sh [--dry-run]
#
# Renames, in coincidence/saved_coincidences/ and coincidence/selected_waveforms/:
#   - each old-tag folder, and every file in it whose name carries the tag
#   - the tag inside pipeline_selection_settings.txt (the pipeline's guard
#     compares it) and sample.txt
# and in $PDS_OUTPUT/pipeline/*/*/ (fits): the tag in sample.txt and in the
# names of the copied cut flow. File time stamps are kept, so the caching
# sees no change. Older date-named rounds (YYYYMMDD_HHMMSS) are not touched.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT_ROOT=${PDS_OUTPUT:-$REPO_DIR/output}
DRY_RUN=0
case ${1:-} in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
esac

new_tag() {  # old tag -> new tag, or empty when not an old pipeline tag
    local old=$1
    [[ $old =~ _[0-9a-f]{8}$ ]] || return 0
    case $old in
        c_m8_*)  echo "default_coinc_${old#c_m8_}" ;;
        c_low_*) echo "inverse_coinc_${old#c_low_}" ;;
        s_*_r*)  echo "no_coinc_${old#s_}" ;;
    esac
}

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

rename_files() {  # DIR OLD NEW: files whose names carry OLD
    local file
    for file in "$1"/*"$2"*; do
        [[ -e $file ]] || continue
        act mv -- "$file" "$1/$(basename "$file" | sed "s|$2|$3|g")"
    done
}

renamed=0
for parent in "$REPO_DIR/coincidence/saved_coincidences" "$REPO_DIR/coincidence/selected_waveforms"; do
    [[ -d $parent ]] || continue
    for dir in "$parent"/*/; do
        old=$(basename "$dir")
        new=$(new_tag "$old")
        [[ -n $new ]] || continue
        echo "$parent/$old -> $new"
        if [[ -e $parent/$new ]]; then
            echo "  skipped: $parent/$new already exists" >&2
            continue
        fi
        rename_files "$parent/$old" "$old" "$new"
        for text in pipeline_selection_settings.txt sample.txt; do
            [[ -f $parent/$old/$text ]] && rewrite "$parent/$old/$text" "$old" "$new"
        done
        act mv -- "$parent/$old" "$parent/$new"
        renamed=$((renamed + 1))
    done
done

# fits: sample.txt and the copied cut flow
for sample in "$OUTPUT_ROOT"/pipeline/*/*/sample.txt; do
    [[ -f $sample ]] || continue
    old=$(sed -n 's/^sample tag : //p' "$sample")
    new=$(new_tag "$old")
    [[ -n $new ]] || continue
    echo "$(dirname "$sample"): $old -> $new"
    rewrite "$sample" "$old" "$new"
    [[ -d $(dirname "$sample")/selection ]] && rename_files "$(dirname "$sample")/selection" "$old" "$new"
    [[ -f $(dirname "$sample")/selection/pipeline_selection_settings.txt ]] \
        && rewrite "$(dirname "$sample")/selection/pipeline_selection_settings.txt" "$old" "$new"
done

echo "Renamed $renamed folder(s)${DRY_RUN:+}$( ((DRY_RUN)) && echo ' (dry run: nothing changed)')."
