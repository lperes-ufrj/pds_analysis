#!/usr/bin/env bash
# Coincidence -> waveform selection -> mean-waveform fit, for one cut set.
# TRIGGER in the cut set: default_coinc, inverse_coinc, custom_coinc, or
# no_coinc (no coincidence stage: bin/only_selection takes every waveform of
# CHANNELS and applies the same quality cuts).
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
#                                               folder: one tag labels the sample;
#                                               e.g. default_coinc_w10_a0_r_292kV_<hash>,
#                                               no_coinc_<channels>_r_292kV_<hash>)
#   $PDS_OUTPUT/pipeline/CUTSET/RUNSET/         fit plots, parameter tables and a
#                                               copy of the cut flow it was fitted on
#
# Each stage is cached per run with a .done_RUN marker, so a reduced pass
# followed by a full pass only processes the runs that are new.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PYTHON=${PYTHON:-python3}

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
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
MODE= TRIGGER= WINDOW_TICKS= MIN_AMPLITUDE_ADC= RATE_THRESHOLDS= INTERVALS=
MAX_AUX_ADC= MAX_FULL_RANGE_ADC= MODULES= CHANNELS= REQUIRE_PEAK= MAX_WAVEFORMS=
CHANNELS_PER_PASS= TEMPLATES= LEFT_CHANNELS= RIGHT_CHANNELS= SAVE_CHANNELS=
# shellcheck source=/dev/null
source "$CUTSET_FILE"
[[ -z $MODE ]] || die "MODE is no longer used: write TRIGGER=no_coinc instead of MODE=single
       (and drop MODE=coincidence) in $CUTSET_FILE"
REQUIRE_PEAK=${REQUIRE_PEAK:-0}
MAX_WAVEFORMS=${MAX_WAVEFORMS:-0}
CHANNELS_PER_PASS=${CHANNELS_PER_PASS:-4}
TEMPLATES=${TEMPLATES:-large_pulse}

# TRIGGER picks the sample (LArSoft map: Mk -> 20k0 20k1, Ck -> 10k0 10k1):
#   default_coinc  trigger M3+M4 (2030..2041) vs M5+M6 (2050..2061), saves M7+M8
#   inverse_coinc  trigger M7+M8 (2070..2081) vs M1+M2 (2010..2021), saves M5+M6
#   custom_coinc   trigger LEFT_CHANNELS vs RIGHT_CHANNELS, saves SAVE_CHANNELS
#   no_coinc       no coincidence: every waveform of CHANNELS (bin/only_selection)
DEFAULT_LEFT="2030 2031 2040 2041"; DEFAULT_RIGHT="2050 2051 2060 2061"
DEFAULT_SAVE="2070 2071 2080 2081"
INVERSE_LEFT="2070 2071 2080 2081"; INVERSE_RIGHT="2010 2011 2020 2021"
INVERSE_SAVE="2050 2051 2060 2061"
case $TRIGGER in
    default_coinc|inverse_coinc) MODE=coincidence
        required="WINDOW_TICKS MIN_AMPLITUDE_ADC MODULES" ;;
    custom_coinc) MODE=coincidence
        required="LEFT_CHANNELS RIGHT_CHANNELS SAVE_CHANNELS WINDOW_TICKS MIN_AMPLITUDE_ADC" ;;
    no_coinc) MODE=single; required="CHANNELS" ;;
    m8)  die "TRIGGER=m8 is now TRIGGER=default_coinc (same sample, same hash)" ;;
    low) die "TRIGGER=low is now TRIGGER=inverse_coinc (same sample, same hash)" ;;
    *) die "TRIGGER must be default_coinc, inverse_coinc, custom_coinc or no_coinc, got '$TRIGGER'" ;;
esac
# MODULES may be empty for no_coinc and custom_coinc: selection only, no fit.
for var in $required INTERVALS MAX_AUX_ADC MAX_FULL_RANGE_ADC; do
    [[ -n ${!var} ]] || die "$var is not set in $CUTSET_FILE (needed by TRIGGER=$TRIGGER)"
done
[[ $REQUIRE_PEAK == [01] ]] || die "REQUIRE_PEAK must be 0 or 1, got '$REQUIRE_PEAK'"
[[ $MAX_WAVEFORMS =~ ^[0-9]+$ ]] || die "MAX_WAVEFORMS must be a non-negative integer"
[[ $CHANNELS_PER_PASS =~ ^[0-9]+$ ]] || die "CHANNELS_PER_PASS must be a non-negative integer"
case $TEMPLATES in large_pulse|francesca) ;;
    *) die "TEMPLATES must be 'large_pulse' or 'francesca', got '$TEMPLATES'" ;; esac

repo_path() { [[ $1 == /* ]] && echo "$1" || echo "$REPO_DIR/$1"; }
INTERVALS=$(repo_path "$INTERVALS")
[[ -f $INTERVALS ]] || die "INTERVALS file not found: $INTERVALS"
if [[ -n $RATE_THRESHOLDS ]]; then
    RATE_THRESHOLDS=$(repo_path "$RATE_THRESHOLDS")
    [[ -d $RATE_THRESHOLDS ]] || die "RATE_THRESHOLDS folder not found: $RATE_THRESHOLDS"
fi

# Channel lists: numbers and/or the keywords all, cathode (10xx), membrane
# (20xx), expanded from the [channel_NNNN] sections of INTERVALS; sorted.
INI_CHANNELS=$(grep -oE '^[[:space:]]*\[channel_[0-9]+\]' "$INTERVALS" | tr -dc '0-9\n')
expand_channels() {  # VARIABLE_NAME VALUE
    local name=$1 token expanded= ch list
    for token in $2; do
        case $token in
            all)      expanded+=" $INI_CHANNELS" ;;
            cathode)  expanded+=" $(grep -E '^1' <<< "$INI_CHANNELS" || true)" ;;
            membrane) expanded+=" $(grep -E '^2' <<< "$INI_CHANNELS" || true)" ;;
            *) [[ $token =~ ^[0-9]+$ ]] \
                   || die "$name takes channel numbers or all/cathode/membrane, got '$token'"
               expanded+=" $token" ;;
        esac
    done
    list=$(printf '%s\n' $expanded | sort -n -u | tr '\n' ' ')
    list=${list% }
    [[ -n $list ]] || die "$name expands to no channel"
    for ch in $list; do
        grep -qx "$ch" <<< "$INI_CHANNELS" \
            || die "$name: channel $ch has no [channel_$ch] section in $INTERVALS"
    done
    echo "$list"
}
# "M3+M4" for 2030 2031 2040 2041
modules_of() {
    local ch out=
    for ch in $1; do
        local m=${ch:0:1}; m=${m/1/C}; m=${m/2/M}; m+=${ch:2:1}
        [[ "+$out+" == *"+$m+"* ]] || out+=${out:++}$m
    done
    echo "$out"
}

case $TRIGGER in
    default_coinc)
        LEFT=$DEFAULT_LEFT; RIGHT=$DEFAULT_RIGHT; SAVE=$DEFAULT_SAVE; HASH_KEY=m8 ;;
    inverse_coinc)
        LEFT=$INVERSE_LEFT; RIGHT=$INVERSE_RIGHT; SAVE=$INVERSE_SAVE; HASH_KEY=low ;;
    custom_coinc)
        LEFT=$(expand_channels LEFT_CHANNELS "$LEFT_CHANNELS")
        RIGHT=$(expand_channels RIGHT_CHANNELS "$RIGHT_CHANNELS")
        SAVE=$(expand_channels SAVE_CHANNELS "$SAVE_CHANNELS")
        HASH_KEY=custom
        # the two standard layouts keep their own names (and folders)
        if [[ "$LEFT|$RIGHT|$SAVE" == "$DEFAULT_LEFT|$DEFAULT_RIGHT|$DEFAULT_SAVE" ]]; then
            echo "[note] these custom_coinc channels are the default_coinc layout; using it" >&2
            TRIGGER=default_coinc; HASH_KEY=m8
        elif [[ "$LEFT|$RIGHT|$SAVE" == "$INVERSE_LEFT|$INVERSE_RIGHT|$INVERSE_SAVE" ]]; then
            echo "[note] these custom_coinc channels are the inverse_coinc layout; using it" >&2
            TRIGGER=inverse_coinc; HASH_KEY=low
        fi ;;
    no_coinc)
        CHANNEL_LABEL=
        [[ $(echo $CHANNELS) =~ ^(all|cathode|membrane)$ ]] && CHANNEL_LABEL=$CHANNELS
        CHANNELS=$(expand_channels CHANNELS "$CHANNELS")
        n_channels=$(wc -w <<< "$CHANNELS")
        if [[ -z $CHANNEL_LABEL ]]; then
            ((n_channels <= 4)) && CHANNEL_LABEL=${CHANNELS// /-} || CHANNEL_LABEL=${n_channels}ch
        fi ;;
esac

# Sample tag: TRIGGER + readable settings + hash of everything that defines
# the sample. The hash keys m8/low/single are the pre-rename names, kept so
# that renamed folders (pipeline/migrate_tags.sh) keep their hashes.
# The [peak_finder] INI section is left out: only the selection stage uses it.
intervals_for_coincidence() {
    awk '/^[[:space:]]*\[/ { skip = ($0 ~ /\[peak_finder\]/) } !skip' "$INTERVALS"
}
RATE_LABEL=$(basename "${RATE_THRESHOLDS:-norate}")
RATE_LABEL=${RATE_LABEL#RateAnalysis_data}
if [[ $MODE == coincidence ]]; then
    COINC_HASH=$( {
        echo "$HASH_KEY $LEFT | $RIGHT | $SAVE | $WINDOW_TICKS | $MIN_AMPLITUDE_ADC"
        echo "rate=${RATE_THRESHOLDS:+$(basename "$RATE_THRESHOLDS")}"
        [[ -n $RATE_THRESHOLDS ]] && cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt
        intervals_for_coincidence
    } | sha1sum | cut -c1-8 )
    COINC_TAG=${TRIGGER}_w${WINDOW_TICKS}_a${MIN_AMPLITUDE_ADC}_r${RATE_LABEL:-default}_${COINC_HASH}
else
    # what defines the population before the quality cuts (channels, rate
    # cut, waveform limit); the intervals and quality cuts are guarded by the
    # selection settings snapshot instead
    COINC_HASH=$( {
        echo "single $CHANNELS | max_waveforms=$MAX_WAVEFORMS"
        echo "rate=${RATE_THRESHOLDS:+$(basename "$RATE_THRESHOLDS")}"
        [[ -n $RATE_THRESHOLDS ]] && cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt
    } | sha1sum | cut -c1-8 )
    LIMIT_LABEL=
    ((MAX_WAVEFORMS)) && LIMIT_LABEL=_n$MAX_WAVEFORMS
    COINC_TAG=no_coinc_${CHANNEL_LABEL}${LIMIT_LABEL}_r${RATE_LABEL:-default}_${COINC_HASH}
fi
COINC_TAG=${COINC_TAG//[^A-Za-z0-9_-]/-}

# The tag spelled out. Two names run through every output:
#   cut set (CUTSET)    the recipe: this .env file's name; names the fit folder
#   sample tag (COINC_TAG)  the data the recipe selects: names the coincidence
#                       and selection folders, shared by cut sets that select
#                       the same sample (they differ only in later choices:
#                       waveform cuts, modules, templates)
span() { set -- $1; [[ $# -gt 1 ]] && echo "$1..${!#}" || echo "$1"; }  # 2030 .. 2041 -> 2030..2041
RATE_TEXT=none
[[ -n $RATE_THRESHOLDS ]] && RATE_TEXT=$(basename "$RATE_THRESHOLDS")
if [[ $MODE == coincidence ]]; then
    SAMPLE_DESCRIPTION="${TRIGGER%_coinc} coincidence: trigger $(modules_of "$LEFT") ($(span "$LEFT")) vs $(modules_of "$RIGHT") ($(span "$RIGHT")), saving $(modules_of "$SAVE") ($(span "$SAVE")), window $WINDOW_TICKS ticks, min amplitude $MIN_AMPLITUDE_ADC ADC"
else
    SAMPLE_DESCRIPTION="no coincidence: every waveform of ${CHANNEL_LABEL//-/ }"
    ((MAX_WAVEFORMS)) && SAMPLE_DESCRIPTION+=", at most $MAX_WAVEFORMS per channel and run"
fi
SAMPLE_DESCRIPTION+=", rate cut $RATE_TEXT"

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
    if [[ $MODE == single ]]; then
        echo "mode=single channels=$CHANNELS"
        echo "require_peak=$REQUIRE_PEAK max_waveforms=$MAX_WAVEFORMS"
    fi
    cat "$INTERVALS"
)

if ((PRINT_TAG)); then
    echo "$COINC_TAG"
    exit 0
fi

mapfile -t RUN_LINES < <(cd "$REPO_DIR" && "$PYTHON" -m pds.runs "$RUN_SET")

# Modules to fit: channels from the template set (pds/modules.py; Mk ->
# 20k0 20k1, Ck -> 10k0 10k1, only arrays with a template). Each module's
# channels must be among those this cut set selects.
mapfile -t MODULE_LINES < <(cd "$REPO_DIR" && "$PYTHON" -m pds.modules --templates "$TEMPLATES")
SELECTED_CHANNELS=${SAVE:-$CHANNELS}
for module in $MODULES; do
    module_line=
    for line in "${MODULE_LINES[@]}"; do
        [[ $line == "$module "* ]] && module_line=$line
    done
    [[ -n $module_line ]] || die "module $module has no template in TEMPLATES=$TEMPLATES" \
        "(modules: $(printf '%s\n' "${MODULE_LINES[@]}" | cut -d' ' -f1 | tr '\n' ' '))"
    for ch in ${module_line#* }; do
        [[ " $SELECTED_CHANNELS " == *" $ch "* ]] && continue
        [[ $MODE == coincidence ]] \
            && die "module $module needs channel $ch, not saved by TRIGGER=$TRIGGER (saved: $SAVE)"
        die "module $module needs channel $ch in CHANNELS (have: $CHANNELS)"
    done
done
((${#RUN_LINES[@]})) || die "no runs in run set $RUN_SET"

run_cmd() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    ((DRY_RUN)) || "$@"
}

if [[ $MODE == single && -n $RATE_THRESHOLDS ]]; then
    missing=
    for ch in $CHANNELS; do
        for line in "${RUN_LINES[@]}"; do
            read -r kv run <<< "$line"
            file=$RATE_THRESHOLDS/equalized_run_${run}_thresholds.txt
            [[ -f $file ]] || continue
            awk -v c="$ch" 'NR > 1 && $1 == c { found = 1 } END { exit !found }' "$file" \
                || { missing+=" $ch"; break; }
        done
    done
    [[ -z $missing ]] || echo "[note] no rate threshold for channel(s)$missing in some runs:" \
        "only_selection skips them there (they stay only in runs without a threshold file)"
fi

cat <<EOF
============================================================
Cut set    (the recipe) : $CUTSET   ($CUTSET_FILE)
Sample tag (the data)   : $COINC_TAG
                          = $SAMPLE_DESCRIPTION
Channels                : ${SAVE:-$CHANNELS}
Run set                 : $RUN_SET (${#RUN_LINES[@]} runs)
Stages                  : $STAGES${FORCE:+   (forced: $FORCE)}
Fit                     : ${MODULES:-none}  (templates: $TEMPLATES)
Selection folder (tag)  : $SELECT_DIR
Fit folder (cut set)    : $FIT_DIR
============================================================
EOF

# Per-run rate-threshold arguments (both modes); empty for the reference run.
set_rate_args() {
    rate_args=()
    local threshold=${RATE_THRESHOLDS:+$RATE_THRESHOLDS/equalized_run_${1}_thresholds.txt}
    if [[ -n $threshold && -f $threshold ]]; then
        rate_args=(--norm-rate-adc-threshold-file "$threshold")
    elif [[ -n $RATE_THRESHOLDS ]]; then
        echo "[note] run $1 has no rate threshold file: no rate cut (reference run)"
    fi
}

# ---------------------------------------------------------------- stage 1
if has "$STAGES" coincidence && [[ $MODE == single ]]; then
    echo "[skip] coincidence: TRIGGER=no_coinc selects every waveform of $CHANNELS"
elif has "$STAGES" coincidence; then
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
        set_rate_args "$run"
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
    SELECT_PROGRAM=plot_wfs_coincidence
    [[ $MODE == single ]] && SELECT_PROGRAM=only_selection
    ((DRY_RUN)) || make -C "$REPO_DIR/coincidence" "$SELECT_PROGRAM"
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
    if [[ ! -f $SELECT_DIR/sample.txt ]] && ! ((DRY_RUN)); then
        printf 'sample tag : %s\n           = %s\nchannels   : %s\nselected by cut set %s (%s)\n' \
            "$COINC_TAG" "$SAMPLE_DESCRIPTION" "${SAVE:-$CHANNELS}" "$CUTSET" "$CUTSET_FILE" \
            > "$SELECT_DIR/sample.txt"
    fi

    for line in "${RUN_LINES[@]}"; do
        read -r kv run <<< "$line"
        marker=$SELECT_DIR/.done_$run
        if [[ -f $marker ]]; then
            echo "[cached] selection    $kv kV  run $run"
            continue
        fi
        input=$REPO_DIR/coincidence/input_lists/input_run$run.txt
        [[ -f $input ]] || die "missing input list $input"
        if [[ $MODE == single ]]; then
            set_rate_args "$run"
            single_args=()
            for ch in $CHANNELS; do single_args+=(--channel "$ch"); done
            ((REQUIRE_PEAK)) && single_args+=(--require-peak)
            ((MAX_WAVEFORMS)) && single_args+=(--max-waveforms "$MAX_WAVEFORMS")
            single_args+=(--channels-per-pass "$CHANNELS_PER_PASS")
            echo "---- selection    $kv kV  run $run  (only_selection)"
            run_cmd "$REPO_DIR/bin/only_selection" \
                --config "$INTERVALS" \
                --output-dir "$SELECT_DIR" \
                --tag "$COINC_TAG" --run "$run" \
                "${single_args[@]}" \
                --max-auxiliary-amplitude "$MAX_AUX_ADC" \
                --max-full-range-amplitude "$MAX_FULL_RANGE_ADC" \
                ${rate_args[@]+"${rate_args[@]}"} \
                "$input"
        else
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
                "$input"
        fi
        ((DRY_RUN)) || touch "$marker"
    done
fi

# ---------------------------------------------------------------- stage 3
# The fit is current when it ran after the last selection change and after
# every selected run of this run set, with the same modules.
fit_is_current() {
    [[ -f $FIT_DIR/.done && $(cat "$FIT_DIR/.done") == "$MODULES templates=$TEMPLATES" ]] || return 1
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
            printf 'cut set    : %s\nsample tag : %s\n           = %s\nselection  : %s\nfit        : %s (templates %s), run set %s\n' \
                "$CUTSET" "$COINC_TAG" "$SAMPLE_DESCRIPTION" "$SELECT_DIR" \
                "${MODULES:-none}" "$TEMPLATES" "$RUN_SET" > "$FIT_DIR/sample.txt"
            # the cut flow this fit was made on: the selection folder may later
            # be replaced by another cut set sharing the coincidence tag
            cp "$settings_file" "$SELECT_DIR"/selection_cuts_*.txt "$FIT_DIR/selection/"
        fi
        [[ -n $MODULES ]] || echo "[skip] fit: MODULES is empty (cut flow copied to $FIT_DIR/selection)"
        # a failing module does not stop the others; the stage still fails
        # (no .done) so the next run retries
        failed=
        for module in $MODULES; do
            echo "---- fit  $module"
            run_cmd "$PYTHON" "$REPO_DIR/fit/waveform_fits/fitting_bertolini_avg.py" \
                "$module" --batch \
                --selection-dir "$SELECT_DIR" \
                --coinc-tag "$COINC_TAG" \
                --run-set "$RUN_SET" \
                --templates "$TEMPLATES" \
                --cutset "$CUTSET" \
                --out-dir "$FIT_DIR" || failed+=" $module"
        done
        [[ -z $failed ]] || die "fit failed for module(s)$failed (the others are in $FIT_DIR)"
        ((DRY_RUN)) || echo "$MODULES templates=$TEMPLATES" > "$FIT_DIR/.done"
    fi
fi

cat <<EOF

Done: cut set $CUTSET on sample $COINC_TAG, run set $RUN_SET.
  cut flow per run : $SELECT_DIR/selection_cuts_*.txt
  mean waveforms   : $SELECT_DIR/mean_median_waveforms_*.png
  fit parameters   : $FIT_DIR/plots_bertolini_avg/<module>/parameters/
Compare cut sets:
  $PYTHON pipeline/compare_cutsets.py --runs $RUN_SET $CUTSET OTHER_CUTSET ...
EOF
