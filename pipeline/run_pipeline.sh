#!/usr/bin/env bash
# Coincidence -> waveform selection -> mean-waveform fit, for one cut set.
#
# Usage:
#   pipeline/run_pipeline.sh CUTSET [options]
#
#   CUTSET               pipeline/cutsets/NAME.env, or a path to a .env file
#   --runs reduced|full  run set from pds/runs.py (default: reduced, 7 fields)
#   --stages LIST        comma list of coincidence,selection,fit (default: all)
#   --force LIST         redo these stages even when their outputs exist
#   --dry-run            print the commands without running them
#   --print-tag          print the cut set's coincidence tag and exit
#
# Environment:
#   PYTHON      interpreter for the fit (default: python3)
#   PDS_OUTPUT  output root; fits go to $PDS_OUTPUT/pipeline/CUTSET/RUNSET/
#
# Outputs:
#   coincidence/saved_coincidences/COINC_TAG/   run_coincidence, shared by every
#                                               cut set with the same coincidence
#                                               settings (COINC_TAG is derived
#                                               from them, so a cached pass is
#                                               reused automatically)
#   coincidence/selected_waveforms/COINC_TAG/   cut flow, mean waveforms, fprompt
#                                               (same name as the coincidence
#                                               folder: one tag labels the sample)
#   $PDS_OUTPUT/pipeline/CUTSET/RUNSET/         fit plots, parameter tables and a
#                                               copy of the cut flow it was fitted on
#
# Each stage is cached per run with a .done_RUN marker, so a reduced pass
# followed by a full pass only processes the runs that are new.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PYTHON=${PYTHON:-python3}

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "Error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
(($# >= 1)) || { usage >&2; exit 2; }
case $1 in -h|--help) usage; exit 0 ;; esac

CUTSET_ARG=$1; shift
RUN_SET=reduced
STAGES=coincidence,selection,fit
FORCE=
DRY_RUN=0
PRINT_TAG=0
while (($#)); do
    case $1 in
        --runs)    RUN_SET=${2:?--runs needs a value}; shift 2 ;;
        --stages)  STAGES=${2:?--stages needs a value}; shift 2 ;;
        --force)   FORCE=${2:?--force needs a value}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --print-tag) PRINT_TAG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
done

if [[ -f $CUTSET_ARG ]]; then
    CUTSET_FILE=$CUTSET_ARG
else
    CUTSET_FILE=$SCRIPT_DIR/cutsets/${CUTSET_ARG%.env}.env
fi
[[ -f $CUTSET_FILE ]] || die "cut set not found: $CUTSET_ARG"
CUTSET_FILE=$(cd -- "$(dirname -- "$CUTSET_FILE")" && pwd)/$(basename -- "$CUTSET_FILE")
CUTSET=$(basename -- "$CUTSET_FILE" .env)
[[ $CUTSET =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "cut-set name may contain only letters, digits, '-' and '_': $CUTSET"

has() { [[ ,$1, == *,$2,* ]]; }
for stage in ${STAGES//,/ } ${FORCE//,/ }; do
    case $stage in coincidence|selection|fit) ;; *) die "unknown stage $stage" ;; esac
done

# ------------------------------------------------------------------ cut set
TRIGGER= WINDOW_TICKS= MIN_AMPLITUDE_ADC= RATE_THRESHOLDS= INTERVALS=
MAX_AUX_ADC= MAX_FULL_RANGE_ADC= MODULES=
# shellcheck source=/dev/null
source "$CUTSET_FILE"

for var in TRIGGER WINDOW_TICKS MIN_AMPLITUDE_ADC INTERVALS \
           MAX_AUX_ADC MAX_FULL_RANGE_ADC MODULES; do
    [[ -n ${!var} ]] || die "$var is not set in $CUTSET_FILE"
done

case $TRIGGER in
    low)
        LEFT="2070 2071 2080 2081"; RIGHT="2010 2011 2020 2021"
        SAVE="2050 2051 2060 2061"; FITTABLE="M5 M6" ;;
    m8)
        LEFT="2030 2031 2040 2041"; RIGHT="2050 2051 2060 2061"
        SAVE="2070 2071 2080 2081"; FITTABLE="M8" ;;
    *) die "TRIGGER must be 'low' or 'm8', got '$TRIGGER'" ;;
esac
for module in $MODULES; do
    [[ " $FITTABLE " == *" $module "* ]] \
        || die "module $module is not saved by TRIGGER=$TRIGGER (saved: $FITTABLE)"
done

repo_path() { [[ $1 == /* ]] && echo "$1" || echo "$REPO_DIR/$1"; }
INTERVALS=$(repo_path "$INTERVALS")
[[ -f $INTERVALS ]] || die "INTERVALS file not found: $INTERVALS"
if [[ -n $RATE_THRESHOLDS ]]; then
    RATE_THRESHOLDS=$(repo_path "$RATE_THRESHOLDS")
    [[ -d $RATE_THRESHOLDS ]] || die "RATE_THRESHOLDS folder not found: $RATE_THRESHOLDS"
fi

# Coincidence tag: readable prefix + hash of everything run_coincidence sees.
# The [peak_finder] INI section is left out: only the selection stage uses it.
intervals_for_coincidence() {
    awk '/^[[:space:]]*\[/ { skip = ($0 ~ /\[peak_finder\]/) } !skip' "$INTERVALS"
}
COINC_HASH=$( {
    echo "$TRIGGER $LEFT | $RIGHT | $SAVE | $WINDOW_TICKS | $MIN_AMPLITUDE_ADC"
    echo "rate=${RATE_THRESHOLDS:+$(basename "$RATE_THRESHOLDS")}"
    [[ -n $RATE_THRESHOLDS ]] && cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt
    intervals_for_coincidence
} | sha1sum | cut -c1-8 )
RATE_LABEL=$(basename "${RATE_THRESHOLDS:-norate}")
RATE_LABEL=${RATE_LABEL#RateAnalysis_data}
COINC_TAG=c_${TRIGGER}_w${WINDOW_TICKS}_a${MIN_AMPLITUDE_ADC}_r${RATE_LABEL:-default}_${COINC_HASH}
COINC_TAG=${COINC_TAG//[^A-Za-z0-9_-]/-}

COINC_DIR=$REPO_DIR/coincidence/saved_coincidences/$COINC_TAG
SELECT_DIR=$REPO_DIR/coincidence/selected_waveforms/$COINC_TAG
OUTPUT_ROOT=${PDS_OUTPUT:-$REPO_DIR/output}
FIT_DIR=$OUTPUT_ROOT/pipeline/$CUTSET/$RUN_SET

# Snapshot of the selection settings. A cut set whose file changed after its
# selection ran must be rerun with --force selection (or given a new name),
# otherwise its folder would mix two selections.
SELECTION_SETTINGS=$(
    echo "coinc_tag=$COINC_TAG"
    echo "max_aux_adc=$MAX_AUX_ADC"
    echo "max_full_range_adc=$MAX_FULL_RANGE_ADC"
    cat "$INTERVALS"
)

if ((PRINT_TAG)); then
    echo "$COINC_TAG"
    exit 0
fi

mapfile -t RUN_LINES < <(cd "$REPO_DIR" && "$PYTHON" -m pds.runs "$RUN_SET")
((${#RUN_LINES[@]})) || die "no runs in run set $RUN_SET"

run_cmd() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    ((DRY_RUN)) || "$@"
}

cat <<EOF
============================================================
Cut set        : $CUTSET ($CUTSET_FILE)
Run set        : $RUN_SET (${#RUN_LINES[@]} runs)
Stages         : $STAGES${FORCE:+   (forced: $FORCE)}
Coincidence tag: $COINC_TAG
Selection dir  : $SELECT_DIR
Fit dir        : $FIT_DIR
============================================================
EOF

# ---------------------------------------------------------------- stage 1
if has "$STAGES" coincidence; then
    ((DRY_RUN)) || make -C "$REPO_DIR/coincidence" run_coincidence
    ((DRY_RUN)) || mkdir -p "$COINC_DIR"
    ((DRY_RUN)) || { echo "# written by pipeline/run_pipeline.sh"
      echo "trigger=$TRIGGER left=$LEFT right=$RIGHT save=$SAVE"
      echo "window_ticks=$WINDOW_TICKS min_amplitude_adc=$MIN_AMPLITUDE_ADC"
      echo "rate_thresholds=${RATE_THRESHOLDS:-none}"
      echo "intervals=$INTERVALS"
    } > "$COINC_DIR/pipeline_coincidence_settings.txt"

    for line in "${RUN_LINES[@]}"; do
        read -r kv run <<< "$line"
        marker=$COINC_DIR/.done_$run
        if [[ -f $marker ]] && ! has "$FORCE" coincidence; then
            echo "[cached] coincidence  $kv kV  run $run"
            continue
        fi
        input=$REPO_DIR/coincidence/input_lists/input_run$run.txt
        [[ -f $input ]] || die "missing input list $input"
        rate_args=()
        threshold=${RATE_THRESHOLDS:+$RATE_THRESHOLDS/equalized_run_${run}_thresholds.txt}
        if [[ -n $threshold && -f $threshold ]]; then
            rate_args=(--norm-rate-adc-threshold-file "$threshold")
        elif [[ -n $RATE_THRESHOLDS ]]; then
            echo "[note] run $run has no rate threshold file: no rate cut (reference run)"
        fi
        echo "---- coincidence  $kv kV  run $run"
        rm -f "$marker" "$COINC_DIR/coincidence_scan_run_${run}_$COINC_TAG.csv"
        # shellcheck disable=SC2086
        run_cmd "$REPO_DIR/bin/run_coincidence" "$input" \
            --run "$run" --timestamp "$COINC_TAG" \
            --output-dir "$REPO_DIR/coincidence/saved_coincidences" \
            --config "$INTERVALS" \
            --channels-coincident-left $LEFT \
            --channels-coincident-right $RIGHT \
            --channels-to-save $SAVE \
            --window-ticks "$WINDOW_TICKS" \
            --min-amplitude-adc "$MIN_AMPLITUDE_ADC" \
            ${rate_args[@]+"${rate_args[@]}"}  # empty-safe under set -u on bash < 4.4
        ((DRY_RUN)) || touch "$marker"
    done
fi

# ---------------------------------------------------------------- stage 2
if has "$STAGES" selection; then
    ((DRY_RUN)) || make -C "$REPO_DIR/coincidence" plot_wfs_coincidence
    if command -v root-config >/dev/null 2>&1; then
        export LD_LIBRARY_PATH="$(root-config --libdir)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    ((DRY_RUN)) || mkdir -p "$SELECT_DIR"
    settings_file=$SELECT_DIR/pipeline_selection_settings.txt
    if has "$FORCE" selection; then
        ((DRY_RUN)) || rm -f "$SELECT_DIR"/.done_* "$settings_file"
    elif [[ -f $settings_file ]] && [[ $(cat "$settings_file") != "$SELECTION_SETTINGS" ]]; then
        die "$SELECT_DIR holds a selection made with other waveform cuts.
       Either cut set $CUTSET changed since its selection ran, or another cut set
       with the same coincidence settings selected into this folder.
       Rerun with --force selection to replace it (fits of other cut sets are kept)."
    fi
    # written only when new, so its time stamp marks the last real change
    # (the fit stage reruns when it is newer than the fit)
    if [[ ! -f $settings_file ]] && ! ((DRY_RUN)); then
        printf '%s\n' "$SELECTION_SETTINGS" > "$settings_file"
    fi

    for line in "${RUN_LINES[@]}"; do
        read -r kv run <<< "$line"
        marker=$SELECT_DIR/.done_$run
        if [[ -f $marker ]]; then
            echo "[cached] selection    $kv kV  run $run"
            continue
        fi
        csv=$COINC_DIR/coincidence_scan_run_${run}_$COINC_TAG.csv
        if [[ ! -f $csv ]] && ! ((DRY_RUN)); then
            die "no coincidence output for run $run ($csv); run the coincidence stage"
        fi
        echo "---- selection    $kv kV  run $run"
        run_cmd "$REPO_DIR/bin/plot_wfs_coincidence" \
            --config "$INTERVALS" \
            --output-dir "$SELECT_DIR" \
            --csv "$csv" \
            --max-auxiliary-amplitude "$MAX_AUX_ADC" \
            --max-full-range-amplitude "$MAX_FULL_RANGE_ADC" \
            "$REPO_DIR/coincidence/input_lists/input_run$run.txt"
        ((DRY_RUN)) || touch "$marker"
    done
fi

# ---------------------------------------------------------------- stage 3
# The fit is current when it ran after the last selection change and after
# every selected run of this run set, with the same modules.
fit_is_current() {
    [[ -f $FIT_DIR/.done && $(cat "$FIT_DIR/.done") == "$MODULES" ]] || return 1
    [[ $FIT_DIR/.done -nt $SELECT_DIR/pipeline_selection_settings.txt ]] || return 1
    local line kv run
    for line in "${RUN_LINES[@]}"; do
        read -r kv run <<< "$line"
        [[ $FIT_DIR/.done -nt $SELECT_DIR/.done_$run ]] || return 1
    done
}
if has "$STAGES" fit; then
    if ! ((DRY_RUN)) && ! has "$FORCE" fit \
        && fit_is_current; then
        echo "[cached] fit  ($FIT_DIR)"
    else
        if ! ((DRY_RUN)); then
            settings_file=$SELECT_DIR/pipeline_selection_settings.txt
            [[ -f $settings_file ]] \
                || die "no selection in $SELECT_DIR; run the selection stage first"
            [[ $(cat "$settings_file") == "$SELECTION_SETTINGS" ]] \
                || die "$SELECT_DIR holds another cut set's selection (different waveform cuts).
       Rerun with --stages selection,fit --force selection to fit cut set $CUTSET."
            mkdir -p "$FIT_DIR/selection"
            cp "$CUTSET_FILE" "$FIT_DIR/cutset.env"
            # the cut flow this fit was made on: the selection folder may later
            # be replaced by another cut set sharing the coincidence tag
            cp "$settings_file" "$SELECT_DIR"/selection_cuts_*.txt "$FIT_DIR/selection/"
        fi
        for module in $MODULES; do
            echo "---- fit  $module"
            run_cmd "$PYTHON" "$REPO_DIR/fit/waveform_fits/fitting_bertolini_avg.py" \
                "$module" --batch \
                --selection-dir "$SELECT_DIR" \
                --coinc-tag "$COINC_TAG" \
                --run-set "$RUN_SET" \
                --out-dir "$FIT_DIR"
        done
        ((DRY_RUN)) || echo "$MODULES" > "$FIT_DIR/.done"
    fi
fi

cat <<EOF

Done: cut set $CUTSET, run set $RUN_SET.
  cut flow per run : $SELECT_DIR/selection_cuts_*.txt
  mean waveforms   : $SELECT_DIR/mean_median_waveforms_*.png
  fit parameters   : $FIT_DIR/plots_bertolini_avg/<module>/parameters/
Compare cut sets:
  $PYTHON pipeline/compare_cutsets.py --runs $RUN_SET $CUTSET OTHER_CUTSET ...
EOF
