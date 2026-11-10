#!/usr/bin/env bash
# Coincidence -> waveform selection -> mean-waveform fit -> light yield vs
# field, for one cut set.
# TRIGGER in the cut set: default_coinc, inverse_coinc, custom_coinc, or
# no_coinc (no coincidence stage: bin/only_selection takes every waveform of
# CHANNELS and applies the same quality cuts).
#
# Usage:
#   pipeline/run_pipeline.sh CUTSET [options]
#
#   CUTSET               pipeline/cutsets/NAME.env, or a path to a .env file
#   --runs reduced|full  run set from pds/runs.py; overrides RUN_SET of the cut
#                        set (default: reduced, 7 fields; full: 22 fields)
#   --stages LIST        comma list of coincidence,selection,fit,lightyield
#                        (default: all)
#   --force LIST         redo these stages even when their outputs exist
#   --dry-run            print the commands without running them
#   --print-tag          print the cut set's sample tag and exit
#   --print WHAT         print and exit: tag (= --print-tag), coinc-tag,
#                        legacy-tag (the old hashed tag, for migrate_tags.sh),
#                        selection-settings, coinc-settings, outputs (the
#                        output folders as KEY=VALUE lines, for the
#                        comparison scripts)
#
# Environment:
#   PYTHON      interpreter for the fit and light yield (default: python3)
#   PDS_OUTPUT  output root; fits go to $PDS_OUTPUT/pipeline/SAMPLE_TAG/RUNSET/
#
# Tags: every sample choice of the cut set spelled out, so the folder name
# says how the sample was made (no hash):
#   coincidence tag  coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV
#                    trigger channels (one side vs the other), saved
#                    channels, min amplitude, rate cut
#   sample tag       coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV_noise500_post2000_full10000
#                    + the waveform cuts
#                    no_coinc_save_M8_r292kV_noise500_post2000_full10000
# The noise and post-signal limits are written _noise<MAX_NOISE_ADC>_post<MAX_POST_ADC>,
# or _aux<N> when both are N (the tag of the single limit they replaced, so
# those samples keep their folders).
# Optional parts appear only when used: _w<WINDOW_TICKS> (a window other
# than the standard 10 ticks), _n<MAX_WAVEFORMS>, _iv-<INI name> (an
# INTERVALS file other than coincidence/waveform_intervals.ini), _peak
# (REQUIRE_PEAK=1). Fit-only choices (MODULES, TEMPLATES, LY_CHANNELS) and
# RUN_SET are not in it: they do not change the sample. The fit and light
# yield folders are named by the sample tag, the run set and, for the fit,
# the template set, so every result traces back to its selection folder.
#
# Outputs:
#   coincidence/saved_coincidences/COINC_TAG/   run_coincidence, shared by every
#                                               cut set with the same coincidence
#                                               choices (no_coinc: none)
#   coincidence/selected_waveforms/SAMPLE_TAG/  cut flow, mean waveforms, fprompt
#   $PDS_OUTPUT/pipeline/SAMPLE_TAG/RUNSET/fit_TEMPLATES/   (fit_TEMPLATES_propagated/
#                                               with FIT_PROPAGATE=1)
#                                               fit plots and parameter tables per
#                                               module, and a copy of the cut flow
#                                               it was fitted on
#   $PDS_OUTPUT/pipeline/SAMPLE_TAG/RUNSET/lightyield/
#                                               S/S0 vs field with the Birks fit
#                                               (analysis/LY_vs_EF/fit_LY_wo_template.py)
#                                               averaged over LY_CHANNELS
# Cut sets giving the same sample tag share these folders: each module fit
# and each LY_CHANNELS list is cached on its own, so they keep each other's
# results.
#
# Each stage is cached per run with a .done_RUN marker, so a reduced pass
# followed by a full pass only processes the runs that are new.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PYTHON=${PYTHON:-python3}

# the comment block at the top of this file, up to the first non-comment line
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "Error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- arguments
(($# >= 1)) || { usage >&2; exit 2; }
case $1 in -h|--help) usage; exit 0 ;; esac

CUTSET_ARG=$1; shift
RUNS_OPTION=
STAGES=coincidence,selection,fit,lightyield
FORCE=
DRY_RUN=0
PRINT=
while (($#)); do
    case $1 in
        --runs)    RUNS_OPTION=${2:?--runs needs a value}; shift 2 ;;
        --stages)  STAGES=${2:?--stages needs a value}; shift 2 ;;
        --force)   FORCE=${2:?--force needs a value}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --print-tag) PRINT=tag; shift ;;
        --print)   PRINT=${2:?--print needs a value}; shift 2 ;;
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
    case $stage in coincidence|selection|fit|lightyield) ;;
        *) die "unknown stage $stage (stages: coincidence, selection, fit, lightyield)" ;; esac
done

# ------------------------------------------------------------------ cut set
MODE= TRIGGER= WINDOW_TICKS= MIN_AMPLITUDE_ADC= RATE_THRESHOLDS= INTERVALS=
MAX_AUX_ADC= MAX_NOISE_ADC= MAX_POST_ADC= MAX_FULL_RANGE_ADC= MODULES= CHANNELS= REQUIRE_PEAK= MAX_WAVEFORMS=
CHANNELS_PER_PASS= TEMPLATES= FIT_PROPAGATE= LEFT_CHANNELS= RIGHT_CHANNELS= SAVE_CHANNELS= RUN_SET=
LY_CHANNELS=
# shellcheck source=/dev/null
source "$CUTSET_FILE"
[[ -z $MODE ]] || die "MODE is no longer used: write TRIGGER=no_coinc instead of MODE=single
       (and drop MODE=coincidence) in $CUTSET_FILE"
[[ -z $MAX_AUX_ADC ]] || die "MAX_AUX_ADC is now two limits: write MAX_NOISE_ADC=$MAX_AUX_ADC and
       MAX_POST_ADC=$MAX_AUX_ADC instead of MAX_AUX_ADC=$MAX_AUX_ADC (same sample, same tag) in $CUTSET_FILE"
REQUIRE_PEAK=${REQUIRE_PEAK:-0}
MAX_WAVEFORMS=${MAX_WAVEFORMS:-0}
CHANNELS_PER_PASS=${CHANNELS_PER_PASS:-4}
TEMPLATES=${TEMPLATES:-large_pulse}
FIT_PROPAGATE=${FIT_PROPAGATE:-0}
RUN_SET=${RUNS_OPTION:-${RUN_SET:-reduced}}
case $RUN_SET in reduced|full) ;;
    *) die "run set must be 'reduced' or 'full', got '$RUN_SET'" ;; esac

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
for var in $required INTERVALS MAX_NOISE_ADC MAX_POST_ADC MAX_FULL_RANGE_ADC; do
    [[ -n ${!var} ]] || die "$var is not set in $CUTSET_FILE (needed by TRIGGER=$TRIGGER)"
done
[[ $MODE == single || $MIN_AMPLITUDE_ADC == false || $MIN_AMPLITUDE_ADC =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || die "MIN_AMPLITUDE_ADC must be a non-negative number or false (no amplitude cut), got '$MIN_AMPLITUDE_ADC'"
[[ $REQUIRE_PEAK == [01] ]] || die "REQUIRE_PEAK must be 0 or 1, got '$REQUIRE_PEAK'"
[[ $MAX_WAVEFORMS =~ ^[0-9]+$ ]] || die "MAX_WAVEFORMS must be a non-negative integer"
[[ $CHANNELS_PER_PASS =~ ^[0-9]+$ ]] || die "CHANNELS_PER_PASS must be a non-negative integer"
case $TEMPLATES in large_pulse|francesca|lucca) ;;
    *) die "TEMPLATES must be 'large_pulse', 'francesca' or 'lucca', got '$TEMPLATES'" ;; esac

[[ $FIT_PROPAGATE == [01] ]] || die "FIT_PROPAGATE must be 0 or 1, got '$FIT_PROPAGATE'"

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
        LEFT=$DEFAULT_LEFT; RIGHT=$DEFAULT_RIGHT; SAVE=$DEFAULT_SAVE ;;
    inverse_coinc)
        LEFT=$INVERSE_LEFT; RIGHT=$INVERSE_RIGHT; SAVE=$INVERSE_SAVE ;;
    custom_coinc)
        LEFT=$(expand_channels LEFT_CHANNELS "$LEFT_CHANNELS")
        RIGHT=$(expand_channels RIGHT_CHANNELS "$RIGHT_CHANNELS")
        SAVE=$(expand_channels SAVE_CHANNELS "$SAVE_CHANNELS")
        # the two standard layouts keep their own names (and folders)
        if [[ "$LEFT|$RIGHT|$SAVE" == "$DEFAULT_LEFT|$DEFAULT_RIGHT|$DEFAULT_SAVE" ]]; then
            echo "[note] these custom_coinc channels are the default_coinc layout; using it" >&2
            TRIGGER=default_coinc
        elif [[ "$LEFT|$RIGHT|$SAVE" == "$INVERSE_LEFT|$INVERSE_RIGHT|$INVERSE_SAVE" ]]; then
            echo "[note] these custom_coinc channels are the inverse_coinc layout; using it" >&2
            TRIGGER=inverse_coinc
        fi ;;
    no_coinc)
        CHANNEL_KEYWORD=
        [[ $(echo $CHANNELS) =~ ^(all|cathode|membrane)$ ]] && CHANNEL_KEYWORD=$CHANNELS
        CHANNELS=$(expand_channels CHANNELS "$CHANNELS") ;;
esac

# ------------------------------------------------------------- sample tags
# Every choice that defines the sample, spelled out (see the header):
#   COINC_TAG   coincidence folder: trigger channels (one side vs the other),
#               saved channels, min amplitude, rate cut, intervals file, and
#               the window when it is not the standard 10 ticks
#   SAMPLE_TAG  selection folder: COINC_TAG (no_coinc: saved channels,
#               waveform limit, rate cut, intervals file) + waveform cuts
# Channels, not the TRIGGER name, are written, so default_coinc,
# inverse_coinc and custom_coinc tags all read the same way.
# The contents of the rate-threshold and intervals files are not in the
# name; the settings snapshots below refuse to reuse a folder made from
# other contents.

# 2080 2081 -> M8: a module with both arrays by name, other channels by
# number, joined by '-' (2010 2011 2021 -> M1-2021)
short_channels() {
    local ch m base out=
    for ch in $1; do
        m=${ch:0:1}; m=${m/1/C}; m=${m/2/M}; m+=${ch:2:1}
        base=${ch:0:3}
        if [[ " $1 " == *" ${base}0 "* && " $1 " == *" ${base}1 "* ]]; then
            [[ -$out- == *-$m-* ]] || out+=${out:+-}$m
        else
            out+=${out:+-}$ch
        fi
    done
    echo "$out"
}
# a number for a tag: 2.5 -> 2p5
tag_number() { echo "${1//./p}"; }
# no_coinc channels: all, cathode or membrane when the list is exactly that
# set of the INTERVALS file, else the short form
channels_label() {
    local keyword
    for keyword in all cathode membrane; do
        [[ $(expand_channels x "$keyword" 2>/dev/null) == "$1" ]] && { echo "$keyword"; return; }
    done
    short_channels "$1"
}
STANDARD_WINDOW_TICKS=10

RATE_TEXT=none RATE_LABEL=none RATE_SHA1=-
if [[ -n $RATE_THRESHOLDS ]]; then
    RATE_TEXT=$(basename "$RATE_THRESHOLDS")
    RATE_LABEL=${RATE_TEXT#RateAnalysis_data_}
    RATE_SHA1=$(cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt | sha1sum | cut -c1-12)
fi
INTERVALS_LABEL=
if [[ $INTERVALS != "$REPO_DIR/coincidence/waveform_intervals.ini" ]]; then
    INTERVALS_LABEL=$(basename "$INTERVALS" .ini)
    INTERVALS_LABEL=_iv-${INTERVALS_LABEL#waveform_intervals_}
fi
# The [peak_finder] INI section is left out: only the selection stage uses it.
intervals_for_coincidence() {
    awk '/^[[:space:]]*\[/ { skip = ($0 ~ /\[peak_finder\]/) } !skip' "$INTERVALS"
}

# equal noise and post-signal limits keep the tag of the single limit they
# replaced (_aux<N>), so the samples made with it keep their folders
if [[ $MAX_NOISE_ADC == "$MAX_POST_ADC" ]]; then
    CUT_LABEL=_aux$(tag_number "$MAX_NOISE_ADC")
else
    CUT_LABEL=_noise$(tag_number "$MAX_NOISE_ADC")_post$(tag_number "$MAX_POST_ADC")
fi
CUT_LABEL+=_full$(tag_number "$MAX_FULL_RANGE_ADC")
if [[ $MODE == coincidence ]]; then
    WINDOW_LABEL=
    [[ $WINDOW_TICKS == "$STANDARD_WINDOW_TICKS" ]] || WINDOW_LABEL=_w$(tag_number "$WINDOW_TICKS")
    COINC_TAG=coinc_$(short_channels "$LEFT")_vs_$(short_channels "$RIGHT")_save_$(short_channels "$SAVE")
    # MIN_AMPLITUDE_ADC=false: no amplitude cut, written anone (as rnone)
    AMPLITUDE_LABEL=_a$(tag_number "$MIN_AMPLITUDE_ADC")
    [[ $MIN_AMPLITUDE_ADC == false ]] && AMPLITUDE_LABEL=_anone
    COINC_TAG+=${WINDOW_LABEL}${AMPLITUDE_LABEL}_r${RATE_LABEL}${INTERVALS_LABEL}
    SAMPLE_TAG=$COINC_TAG$CUT_LABEL
else
    COINC_TAG=
    LIMIT_LABEL=
    ((MAX_WAVEFORMS)) && LIMIT_LABEL=_n$MAX_WAVEFORMS
    ((REQUIRE_PEAK)) && CUT_LABEL+=_peak
    SAMPLE_TAG=no_coinc_save_$(channels_label "$CHANNELS")${LIMIT_LABEL}_r${RATE_LABEL}${INTERVALS_LABEL}$CUT_LABEL
fi
COINC_TAG=${COINC_TAG//[^A-Za-z0-9_-]/-}
SAMPLE_TAG=${SAMPLE_TAG//[^A-Za-z0-9_-]/-}

# The tag of the previous scheme (readable prefix + hash), only to find and
# rename old folders: pipeline/migrate_tags.sh. The hash keys m8/low/single
# are the names of an even older scheme.
legacy_tag() {
    local key hash rate=$(basename "${RATE_THRESHOLDS:-norate}") label n tag
    rate=${rate#RateAnalysis_data}
    if [[ $MODE == coincidence ]]; then
        case $TRIGGER in default_coinc) key=m8 ;; inverse_coinc) key=low ;; *) key=custom ;; esac
        hash=$( {
            echo "$key $LEFT | $RIGHT | $SAVE | $WINDOW_TICKS | $MIN_AMPLITUDE_ADC"
            echo "rate=${RATE_THRESHOLDS:+$(basename "$RATE_THRESHOLDS")}"
            [[ -n $RATE_THRESHOLDS ]] && cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt
            intervals_for_coincidence
        } | sha1sum | cut -c1-8 )
        tag=${TRIGGER}_w${WINDOW_TICKS}_a${MIN_AMPLITUDE_ADC}_r${rate:-default}_$hash
    else
        hash=$( {
            echo "single $CHANNELS | max_waveforms=$MAX_WAVEFORMS"
            echo "rate=${RATE_THRESHOLDS:+$(basename "$RATE_THRESHOLDS")}"
            [[ -n $RATE_THRESHOLDS ]] && cat "$RATE_THRESHOLDS"/equalized_run_*_thresholds.txt
        } | sha1sum | cut -c1-8 )
        n=$(wc -w <<< "$CHANNELS")
        label=$CHANNEL_KEYWORD
        [[ -n $label ]] || { ((n <= 4)) && label=${CHANNELS// /-} || label=${n}ch; }
        tag=no_coinc_$label
        ((MAX_WAVEFORMS)) && tag+=_n$MAX_WAVEFORMS
        tag+=_r${rate:-default}_$hash
    fi
    echo "${tag//[^A-Za-z0-9_-]/-}"
}

# The tags in words. Two names run through every output:
#   cut set (CUTSET)       the recipe: this .env file's name; recorded in the
#                          fit folder's sample.txt and in the plot legends
#   sample tag (SAMPLE_TAG) the data the recipe selects: names the selection,
#                          fit and light-yield folders (and, without the cuts,
#                          the coincidence folder)
span() { set -- $1; [[ $# -gt 1 ]] && echo "$1..${!#}" || echo "$1"; }  # 2030 .. 2041 -> 2030..2041
if [[ $MODE == coincidence ]]; then
    SAMPLE_DESCRIPTION="${TRIGGER%_coinc} coincidence: trigger $(modules_of "$LEFT") ($(span "$LEFT")) vs $(modules_of "$RIGHT") ($(span "$RIGHT")), saving $(modules_of "$SAVE") ($(span "$SAVE")), window $WINDOW_TICKS ticks, "
    if [[ $MIN_AMPLITUDE_ADC == false ]]; then
        SAMPLE_DESCRIPTION+="no min amplitude"
    else
        SAMPLE_DESCRIPTION+="min amplitude $MIN_AMPLITUDE_ADC ADC"
    fi
else
    SAMPLE_DESCRIPTION="no coincidence: every waveform of ${CHANNEL_KEYWORD:-$CHANNELS}"
    ((MAX_WAVEFORMS)) && SAMPLE_DESCRIPTION+=", at most $MAX_WAVEFORMS per channel and run"
fi
SAMPLE_DESCRIPTION+=", rate cut $RATE_TEXT, intervals $(basename "$INTERVALS")"
SAMPLE_DESCRIPTION+=", noise < $MAX_NOISE_ADC ADC, post-signal < $MAX_POST_ADC ADC, full range < $MAX_FULL_RANGE_ADC ADC"
[[ $MODE == single ]] && ((REQUIRE_PEAK)) && SAMPLE_DESCRIPTION+=", significant peak required"

COINC_DIR=$REPO_DIR/coincidence/saved_coincidences/$COINC_TAG
SELECT_DIR=$REPO_DIR/coincidence/selected_waveforms/$SAMPLE_TAG
OUTPUT_ROOT=${PDS_OUTPUT:-$REPO_DIR/output}
# the fit and light yield of this sample and run set; the fit depends on the
# template set too, the light yield does not
RESULT_DIR=$OUTPUT_ROOT/pipeline/$SAMPLE_TAG/$RUN_SET
FIT_NAME=$TEMPLATES
((FIT_PROPAGATE)) && FIT_NAME+=_propagated
FIT_DIR=$RESULT_DIR/fit_$FIT_NAME
LY_DIR=$RESULT_DIR/lightyield

# Settings snapshots: what a folder was made from, including the contents of
# the threshold and intervals files, which the tags only name. A folder made
# from other contents is refused until the stage is rerun with --force.
COINC_SETTINGS=
[[ $MODE == coincidence ]] && COINC_SETTINGS=$(
    echo "trigger=$TRIGGER left=$LEFT right=$RIGHT save=$SAVE"
    echo "window_ticks=$WINDOW_TICKS min_amplitude_adc=$MIN_AMPLITUDE_ADC"
    echo "rate_thresholds=$RATE_TEXT sha1=$RATE_SHA1"
    echo "intervals=$(basename "$INTERVALS") sha1=$(intervals_for_coincidence | sha1sum | cut -c1-12)"
)
# Lines 3.. match the previous scheme's snapshot from line 2 on, which
# migrate_tags.sh relies on.
SELECTION_SETTINGS=$(
    echo "sample_tag=$SAMPLE_TAG"
    echo "rate_thresholds=$RATE_TEXT sha1=$RATE_SHA1"
    # one line when the limits are equal: the snapshot of the samples made
    # with the single limit, which are then reused without --force
    if [[ $MAX_NOISE_ADC == "$MAX_POST_ADC" ]]; then
        echo "max_aux_adc=$MAX_NOISE_ADC"
    else
        echo "max_noise_adc=$MAX_NOISE_ADC max_post_adc=$MAX_POST_ADC"
    fi
    echo "max_full_range_adc=$MAX_FULL_RANGE_ADC"
    # the noise cut became max |ADC - baseline|; without this line, folders
    # made with the old positive-maximum cut would be reused as current
    echo "noise_cut=absolute"
    if [[ $MODE == single ]]; then
        echo "mode=single channels=$CHANNELS"
        echo "require_peak=$REQUIRE_PEAK max_waveforms=$MAX_WAVEFORMS"
    fi
    cat "$INTERVALS"
)

case $PRINT in
    ""|outputs) ;;  # outputs: after the light-yield channels, below
    tag)                echo "$SAMPLE_TAG"; exit 0 ;;
    coinc-tag)          echo "$COINC_TAG"; exit 0 ;;
    legacy-tag)         legacy_tag; exit 0 ;;
    selection-settings) printf '%s\n' "$SELECTION_SETTINGS"; exit 0 ;;
    coinc-settings)     [[ $MODE == coincidence ]] && printf '%s\n' "$COINC_SETTINGS"; exit 0 ;;
    *) die "--print takes tag, coinc-tag, legacy-tag, selection-settings, coinc-settings or outputs" ;;
esac

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

# Light-yield channels: LY_CHANNELS, else the channels of MODULES (as fitted),
# else every selected channel. Averaged into one S/S0 curve.
if [[ -n $LY_CHANNELS ]]; then
    LY_CHANNELS=$(expand_channels LY_CHANNELS "$LY_CHANNELS")
    for ch in $LY_CHANNELS; do
        [[ " $SELECTED_CHANNELS " == *" $ch "* ]] \
            || die "LY_CHANNELS: channel $ch is not selected by this cut set (selected: $SELECTED_CHANNELS)"
    done
elif [[ -n $MODULES ]]; then
    for module in $MODULES; do
        for line in "${MODULE_LINES[@]}"; do
            [[ $line == "$module "* ]] && LY_CHANNELS+=" ${line#* }"
        done
    done
    LY_CHANNELS=$(printf '%s\n' $LY_CHANNELS | sort -n -u | tr '\n' ' ')
    LY_CHANNELS=${LY_CHANNELS% }
else
    LY_CHANNELS=$SELECTED_CHANNELS
fi
# light-yield results are named by their channel list (2080 2081 -> chs_2080_2081)
LY_LABEL=chs_${LY_CHANNELS// /_}

if [[ $PRINT == outputs ]]; then
    printf '%s\n' "cutset=$CUTSET" "tag=$SAMPLE_TAG" "run_set=$RUN_SET" \
        "templates=$TEMPLATES" "modules=$MODULES" "selection_dir=$SELECT_DIR" \
        "fit_dir=$FIT_DIR" "lightyield_dir=$LY_DIR" "lightyield_channels=$LY_CHANNELS"
    exit 0
fi

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
Sample tag (the data)   : $SAMPLE_TAG
                          = $SAMPLE_DESCRIPTION
${COINC_TAG:+Coincidence tag         : $COINC_TAG
}Channels                : ${SAVE:-$CHANNELS}
Run set                 : $RUN_SET (${#RUN_LINES[@]} runs)
Stages                  : $STAGES${FORCE:+   (forced: $FORCE)}
Fit                     : ${MODULES:-none}  (templates: $TEMPLATES)
Light yield channels    : $LY_CHANNELS
Selection folder (tag)  : $SELECT_DIR
Fit folder (tag)        : $FIT_DIR
Light-yield folder (tag): $LY_DIR
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
    settings_file=$COINC_DIR/pipeline_coincidence_settings.txt
    if has "$FORCE" coincidence; then
        ((DRY_RUN)) || rm -f "$settings_file"
    elif [[ -f $settings_file ]] && [[ $(cat "$settings_file") != "$COINC_SETTINGS" ]]; then
        die "$COINC_DIR was made from other inputs:
$(diff <(cat "$settings_file") <(printf '%s\n' "$COINC_SETTINGS") | sed 's/^/       /')
       The rate-threshold or intervals file changed since. Rerun with
       --force coincidence (and --force selection) to replace it."
    fi
    if [[ ! -f $settings_file ]] && ! ((DRY_RUN)); then
        printf '%s\n' "$COINC_SETTINGS" > "$settings_file"
    fi

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
        die "$SELECT_DIR was made from other inputs:
$(diff <(cat "$settings_file") <(printf '%s\n' "$SELECTION_SETTINGS") | sed 's/^/       /')
       The rate-threshold or intervals file, or a cut definition, changed
       since its selection ran.
       Rerun with --force selection to replace it."
    fi
    # written only when new, so its time stamp marks the last real change
    # (the fit stage reruns when it is newer than the fit)
    if [[ ! -f $settings_file ]] && ! ((DRY_RUN)); then
        printf '%s\n' "$SELECTION_SETTINGS" > "$settings_file"
    fi
    if [[ ! -f $SELECT_DIR/sample.txt ]] && ! ((DRY_RUN)); then
        printf 'sample tag : %s\n           = %s\nchannels   : %s\nselected by cut set %s (%s)\n' \
            "$SAMPLE_TAG" "$SAMPLE_DESCRIPTION" "${SAVE:-$CHANNELS}" "$CUTSET" "$CUTSET_FILE" \
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
                --tag "$SAMPLE_TAG" --run "$run" \
                "${single_args[@]}" \
                --max-noise-amplitude "$MAX_NOISE_ADC" \
                --max-post-signal-amplitude "$MAX_POST_ADC" \
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
                --tag "$SAMPLE_TAG" \
                --max-noise-amplitude "$MAX_NOISE_ADC" \
                --max-post-signal-amplitude "$MAX_POST_ADC" \
                --max-full-range-amplitude "$MAX_FULL_RANGE_ADC" \
                "$input"
        fi
        ((DRY_RUN)) || touch "$marker"
    done
fi

# ------------------------------------------- shared by the fit and light yield
# A result reading the selection is current when its MARKER holds the same
# settings (KEY) and is newer than the last selection change and every
# selected run of this run set.
is_current() {  # MARKER KEY
    [[ -f $1 && $(cat "$1") == "$2" ]] || return 1
    [[ $1 -nt $SELECT_DIR/pipeline_selection_settings.txt ]] || return 1
    local line kv run
    for line in "${RUN_LINES[@]}"; do
        read -r kv run <<< "$line"
        [[ $1 -nt $SELECT_DIR/.done_$run ]] || return 1
    done
}
# The selection folder must hold this cut set's selection.
require_own_selection() {  # STAGE
    local settings_file=$SELECT_DIR/pipeline_selection_settings.txt
    [[ -f $settings_file ]] \
        || die "no selection in $SELECT_DIR; run the selection stage first"
    [[ $(cat "$settings_file") == "$SELECTION_SETTINGS" ]] \
        || die "$SELECT_DIR was selected from other inputs (the rate-threshold or
       intervals file changed since). Rerun with --stages selection,$1 --force selection."
}

# ---------------------------------------------------------------- stage 3
# FIT_DIR is shared by the cut sets giving this sample tag, run set and
# template set. Each module is cached on its own (plots_bertolini_avg/MODULE/
# .done), so a cut set fitting other modules keeps the fits already there;
# FIT_DIR/.done marks the cut-flow copy, made with the last fit.
FIT_KEY="sample=$SAMPLE_TAG templates=$TEMPLATES"
module_marker() { echo "$FIT_DIR/plots_bertolini_avg/$1/.done"; }
# FIT_PROPAGATE=1: fit with propagated uncertainties, in its own folder
# (fit_TEMPLATES_propagated), so both fits of a sample can be compared
FIT_ARGS=()
if ((FIT_PROPAGATE)); then
    FIT_KEY+=" propagate=1"
    FIT_ARGS+=(--propagate-uncertainties)
fi
if has "$STAGES" fit; then
    to_fit=
    for module in $MODULES; do
        if ! ((DRY_RUN)) && ! has "$FORCE" fit \
            && is_current "$(module_marker "$module")" "$FIT_KEY module=$module"; then
            echo "[cached] fit  $module  ($FIT_DIR)"
        else
            to_fit+=" $module"
        fi
    done
    if [[ -n $to_fit ]] || has "$FORCE" fit || ! is_current "$FIT_DIR/.done" "$FIT_KEY"; then
        if ! ((DRY_RUN)); then
            require_own_selection fit
            settings_file=$SELECT_DIR/pipeline_selection_settings.txt
            mkdir -p "$FIT_DIR/selection"
            cp "$CUTSET_FILE" "$FIT_DIR/cutset.env"
            printf 'cut set    : %s\nsample tag : %s\n           = %s\nselection  : %s\nfit        : %s (templates %s), run set %s\n' \
                "$CUTSET" "$SAMPLE_TAG" "$SAMPLE_DESCRIPTION" "$SELECT_DIR" \
                "${MODULES:-none}" "$TEMPLATES" "$RUN_SET" > "$FIT_DIR/sample.txt"
            # the cut flow these fits are made on: the selection folder may
            # later be replaced (--force selection)
            rm -f "$FIT_DIR/.done" "$FIT_DIR"/selection/*
            cp "$settings_file" "$SELECT_DIR"/selection_cuts_*.txt "$FIT_DIR/selection/"
            # fits made on another selection than this copy, and the ones to
            # redo, go
            for dir in "$FIT_DIR"/plots_bertolini_avg/*/; do
                [[ -d $dir ]] || continue
                module=$(basename "$dir")
                if [[ " $to_fit " == *" $module "* ]] \
                    || ! is_current "$dir.done" "$FIT_KEY module=$module"; then
                    rm -rf "$dir"
                fi
            done
            echo "$FIT_KEY" > "$FIT_DIR/.done"
        fi
    fi
    [[ -n $MODULES ]] || echo "[skip] fit: MODULES is empty (cut flow copied to $FIT_DIR/selection)"
    # a failing module does not stop the others; the stage still fails and
    # the module has no marker, so the next run retries it
    failed=
    for module in $to_fit; do
        echo "---- fit  $module"
        if run_cmd "$PYTHON" "$REPO_DIR/fit/waveform_fits/fitting_bertolini_avg.py" \
            "$module" --batch \
            --selection-dir "$SELECT_DIR" \
            --coinc-tag "$SAMPLE_TAG" \
            --run-set "$RUN_SET" \
            --templates "$TEMPLATES" \
            ${FIT_ARGS[@]+"${FIT_ARGS[@]}"} \
            --cutset "$CUTSET" \
            --out-dir "$FIT_DIR"; then
            if ! ((DRY_RUN)); then
                mkdir -p "$FIT_DIR/plots_bertolini_avg/$module"
                echo "$FIT_KEY module=$module" > "$(module_marker "$module")"
            fi
        else
            failed+=" $module"
        fi
    done
    [[ -z $failed ]] || die "fit failed for module(s)$failed (the others are in $FIT_DIR)"
fi

# ---------------------------------------------------------------- stage 4
# S/S0 vs field from the integral of the mean waveforms of LY_CHANNELS (the
# selection's channel_<ch>_*.csv), normalized to 0 kV, with a Birks fit.
# LY_DIR is shared by the cut sets giving this sample tag and run set; each
# channel list has its own files and marker (.done_chs_2080_2081).
LY_KEY="sample=$SAMPLE_TAG channels=$LY_CHANNELS"
LY_MARKER=$LY_DIR/.done_$LY_LABEL
if has "$STAGES" lightyield; then
    if ! ((DRY_RUN)) && ! has "$FORCE" lightyield \
        && is_current "$LY_MARKER" "$LY_KEY"; then
        echo "[cached] lightyield  $LY_CHANNELS  ($LY_DIR)"
    else
        if ! ((DRY_RUN)); then
            require_own_selection lightyield
            mkdir -p "$LY_DIR"
            # the previous tables of this channel list go (time-stamped names:
            # fit_LY_wo_template_chs_2080_2081_YYYYMMDD_HHMMSS.{png,txt})
            rm -f "$LY_MARKER" "$LY_DIR/fit_LY_wo_template_${LY_LABEL}_"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].{png,txt}
        fi
        echo "---- lightyield  channels $LY_CHANNELS"
        # shellcheck disable=SC2086
        run_cmd "$PYTHON" "$REPO_DIR/analysis/LY_vs_EF/fit_LY_wo_template.py" \
            "$SAMPLE_TAG" --batch \
            --cutset "$CUTSET" \
            --runs "$RUN_SET" \
            --channels $LY_CHANNELS \
            --out "$LY_DIR" \
            || die "light yield failed (channels $LY_CHANNELS; each needs its 0 kV run 039510)"
        ((DRY_RUN)) || echo "$LY_KEY" > "$LY_MARKER"
    fi
fi

cat <<EOF

Done: cut set $CUTSET on sample $SAMPLE_TAG, run set $RUN_SET.
  cut flow per run : $SELECT_DIR/selection_cuts_*.txt
  mean waveforms   : $SELECT_DIR/mean_median_waveforms_*.png
  fit parameters   : $FIT_DIR/plots_bertolini_avg/<module>/parameters/
  light yield      : $LY_DIR/fit_LY_wo_template_${LY_LABEL}_*.{png,txt}
Compare cut sets:
  $PYTHON pipeline/compare_cutsets.py --runs $RUN_SET $CUTSET OTHER_CUTSET ...
EOF
