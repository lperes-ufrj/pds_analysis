#!/usr/bin/env bash
# Move fits and light yields from the cut-set folders of the previous layout
#
#   $PDS_OUTPUT/pipeline/CUTSET/RUNSET/{plots_bertolini_avg,selection,lightyield,...}
#
# to the sample-tag folders run_pipeline.sh now writes:
#
#   $PDS_OUTPUT/pipeline/SAMPLE_TAG/RUNSET/fit_TEMPLATES/   fit, cut-flow copy,
#                                                          sample.txt, cutset.env
#   $PDS_OUTPUT/pipeline/SAMPLE_TAG/RUNSET/lightyield/
#
# SAMPLE_TAG is the tag the results were made on (sample.txt and the .done
# markers), not necessarily the cut set's tag today. Nothing is rerun: the
# completion markers are rewritten in the new form (one per module fit, one
# per light-yield channel list) with their time stamps kept, so the pipeline
# finds the results cached. A folder is skipped when it has no sample.txt
# (a fit from before it was written: rerun its fit) or when its target
# exists (another cut set already gave that sample tag a fit).
# Run pipeline/migrate_tags.sh first if the fits still carry hashed tags.
#
# Usage:
#   pipeline/migrate_fit_folders.sh [--dry-run]
#
#   --dry-run  print what would change, change nothing

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PIPELINE_DIR=${PDS_OUTPUT:-$REPO_DIR/output}/pipeline

DRY_RUN=0
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

act() { printf '  %s\n' "$*"; ((DRY_RUN)) || "$@"; }

# write TEXT to FILE with the time stamp of REFERENCE (the pipeline compares
# its markers against the selection's time stamps)
write_marker() {  # FILE TEXT REFERENCE
    echo "  write $1: $2"
    ((DRY_RUN)) && return 0
    local stamp
    stamp=$(mktemp)
    touch -r "$3" "$stamp"
    printf '%s\n' "$2" > "$1"
    touch -r "$stamp" "$1"
    rm -f "$stamp"
}

# value of KEY in a marker line "sample=TAG modules=M5 M8 templates=SET"
marker_value() {  # FILE KEY
    sed -n "s/.*\\b$2=\\(.*\\)/\\1/p" "$1" | sed 's/ [a-z_]*=.*//'
}

moved=0 skipped=0
for old in "$PIPELINE_DIR"/*/reduced "$PIPELINE_DIR"/*/full; do
    [[ -d $old ]] || continue
    # only folders of the previous layout: a fit or light yield directly in
    # the run-set folder (the new layout has them in fit_*/ and lightyield/
    # with sample.txt one level down)
    [[ -d $old/plots_bertolini_avg || -f $old/.done || -f $old/sample.txt ]] || continue
    cutset=$(basename "$(dirname "$old")")
    runs=$(basename "$old")
    echo "== $cutset/$runs"
    info=$old/sample.txt
    if [[ ! -f $info ]]; then
        echo "  skipped: no sample.txt (fitted before it was written); rerun its fit"
        skipped=$((skipped + 1)); continue
    fi
    tag=$(sed -n 's/^sample tag : //p' "$info")
    templates=$(sed -n 's/^fit *: .*(templates \([A-Za-z0-9_]*\)).*/\1/p' "$info")
    if [[ -z $tag || -z $templates ]]; then
        echo "  skipped: no sample tag or templates in $info"
        skipped=$((skipped + 1)); continue
    fi
    fit=$PIPELINE_DIR/$tag/$runs/fit_$templates

    ly_tag=$tag ly_channels=
    if [[ -f $old/lightyield/.done ]]; then
        ly_tag=$(marker_value "$old/lightyield/.done" sample)
        ly_channels=$(marker_value "$old/lightyield/.done" channels)
        [[ -n $ly_tag ]] || ly_tag=$tag
    fi
    ly=$PIPELINE_DIR/$ly_tag/$runs/lightyield
    if [[ -e $fit ]]; then
        echo "  skipped: $fit exists"
        skipped=$((skipped + 1)); continue
    fi
    if [[ -d $old/lightyield && -e $ly ]]; then
        echo "  skipped: $ly exists (move or merge $old/lightyield by hand)"
        skipped=$((skipped + 1)); continue
    fi
    echo "  -> $fit"

    # ------------------------------------------------------------ fit
    # one marker per module, from the folder's marker when it is complete
    # and of this tag; without one the module is refitted
    if [[ -f $old/.done ]] && [[ $(marker_value "$old/.done" sample) == "$tag" ]]; then
        for module in $(marker_value "$old/.done" modules); do
            [[ -d $old/plots_bertolini_avg/$module ]] || continue
            write_marker "$old/plots_bertolini_avg/$module/.done" \
                "sample=$tag templates=$templates module=$module" "$old/.done"
        done
        write_marker "$old/.done" "sample=$tag templates=$templates" "$old/.done"
    elif [[ -f $old/.done ]]; then
        echo "  note: $old/.done is not of sample $tag; its modules will be refitted"
        act rm -f "$old/.done"
    fi

    # ---------------------------------------------------- light yield
    if [[ -d $old/lightyield ]]; then
        if [[ -n $ly_channels ]]; then
            act mv "$old/lightyield/.done" "$old/lightyield/.done_chs_${ly_channels// /_}"
        fi
        [[ $ly_tag == "$tag" ]] || echo "  light yield of sample $ly_tag -> $ly"
        act mkdir -p "$(dirname "$ly")"
        act mv "$old/lightyield" "$ly"
    fi

    act mkdir -p "$(dirname "$fit")"
    act mv "$old" "$fit"
    if ! ((DRY_RUN)); then
        rmdir "$PIPELINE_DIR/$cutset" 2>/dev/null \
            || echo "  kept $PIPELINE_DIR/$cutset (not empty)"
    fi
    moved=$((moved + 1))
done

echo "Moved $moved folder(s), skipped $skipped$( ((DRY_RUN)) && echo ' (dry run: nothing changed)')."
