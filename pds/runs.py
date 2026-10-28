"""Electric-field scan: run <-> cathode HV.

Single source for the run map, shared by the batch scripts in deconvolution/
and fit/ and by the field plots.

The scan was taken twice: rising voltage (17 points, ~10 kV steps) and
falling voltage (9 points, ~20 kV steps). Run 039510 (0 kV) is physically the
same run in both branches, so it is not an independent measurement.
"""

# HV label [kV] -> run number, rising branch
EF_SCAN_UP = {
    0: "039510", 10: "039511", 20: "039512", 30: "039514", 40: "039515",
    50: "039516", 60: "039517", 70: "039518", 80: "039519", 90: "039521",
    100: "039522", 110: "039523", 120: "039525", 130: "039526",
    140: "039527", 150: "039528", 155.7: "039529",
}

# HV label [kV] -> run number, falling branch
EF_SCAN_DOWN = {
    155.7: "039500", 140: "039501", 120: "039502", 100: "039503",
    80: "039504", 60: "039506", 40: "039507", 20: "039508", 0: "039510",
}

# run -> (HV [kV], branch)
FIELD_OF_RUN = {}
for _kv, _run in EF_SCAN_UP.items():
    FIELD_OF_RUN[_run] = (_kv, "up")
for _kv, _run in EF_SCAN_DOWN.items():
    FIELD_OF_RUN.setdefault(_run, (_kv, "down"))


# HV label [kV] -> run number, high-field scan (Sep 2026). Each HV was taken
# twice; the first run of each pair is used (the second ones are 043381 at
# 240 kV, 043384 at 205 kV, 043387 at 270 kV and 043390 at 154 kV). 041523 is
# the 292 kV rate-equalization reference and has no equalized threshold file.
EF_SCAN_HIGH = {
    154: "043389", 205: "043383", 240: "043380", 270: "043386", 292: "041523",
}
for _kv, _run in EF_SCAN_HIGH.items():
    FIELD_OF_RUN.setdefault(_run, (_kv, "high"))

# Field points used by the template-convolved fits (fit/waveform_fits/): the
# rising branch below 155.7 kV plus the high-field scan. The falling branch is
# left out on purpose; it only repeats fields that are already here.
FIT_SCAN = {kv: run for kv, run in EF_SCAN_UP.items()}
FIT_SCAN.update(EF_SCAN_HIGH)
FIT_SCAN = dict(sorted(FIT_SCAN.items()))

# Reduced scan for fast cut-validation passes (pipeline/run_pipeline.sh):
# 7 fields covering 0-292 kV, 4 of them at <= 40 kV where most field effects
# show. 0 kV must stay in: the fits normalize every field to its peak.
REDUCED_FIELDS = (0, 10, 20, 40, 100, 205, 292)
REDUCED_SCAN = {kv: FIT_SCAN[kv] for kv in REDUCED_FIELDS}

RUN_SETS = {"reduced": REDUCED_SCAN, "full": FIT_SCAN}


def run_set(name):
    """{HV [kV]: run} of a named run set ("reduced" or "full"), ascending HV."""
    try:
        return dict(RUN_SETS[name])
    except KeyError:
        raise ValueError(f"unknown run set {name!r}; valid: {', '.join(RUN_SETS)}")


def runs_of(branch="up"):
    """Ordered [(HV, run)] of a branch ("up", "down" or "all").

    "all" keeps both branches and deduplicates by run, so the 0 kV run that
    appears in both is listed once and the total is 25, not 26.
    """
    pairs = []
    if branch in ("up", "all"):
        pairs += list(EF_SCAN_UP.items())
    if branch in ("down", "all"):
        pairs += list(EF_SCAN_DOWN.items())

    seen, out = set(), []
    for kv, run in pairs:
        if run in seen:
            continue
        seen.add(run)
        out.append((kv, run))
    return sorted(out)


def field_of(run):
    """HV [kV] of a run, or None if the run is not in the scan."""
    entry = FIELD_OF_RUN.get(str(run))
    return entry[0] if entry else None


if __name__ == "__main__":
    # Shell helper: `python3 -m pds.runs reduced` prints "HV run" per line.
    import sys
    for _kv, _run in run_set(sys.argv[1] if len(sys.argv) > 1 else "reduced").items():
        print(_kv, _run)
