import numpy as np
try:
    from numpy import trapezoid
except ImportError:  # NumPy < 2.0 in the Gallery runtime.
    from numpy import trapz as trapezoid
from pathlib import Path
import re

# Integration window, half-open sample range [first, last). Keep synchronized
# with INTEGRAL_FIRST_SAMPLE / INTEGRAL_LAST_SAMPLE in
# coincidence/coincidence_lib.hpp: plot_wfs_coincidence and only_selection
# write the same trapezoid per waveform (integral_50_500 column of the
# fprompt_*.csv files), whose multiplicity-weighted mean equals the integral
# of the mean waveform computed here.
INTEGRAL_FIRST_SAMPLE = 50
INTEGRAL_LAST_SAMPLE = 500


def calc_integral_and_error(waveform, y_err):
    """Return (I - sigma, I, I + sigma) for uncorrelated sample errors.

    x is treated as exact; y_err contains standard errors on y. Trapezoidal
    endpoint and interior weights also support nonuniform sample spacing.
    """
    y = waveform[INTEGRAL_FIRST_SAMPLE:INTEGRAL_LAST_SAMPLE]

    integral_central = trapezoid(y)

    integral_lower = trapezoid(y-y_err)
    integral_upper = trapezoid(y+y_err)

    return integral_lower, integral_central, integral_upper

def read_txt_error_file(sample_label,channels):
    """Return {run: {channel: baseline noise in ADC}} (not error on the mean)."""
    from pds import paths
    path_waveforms = paths.COINC_DIR / sample_label

    txt_suffix = f"{sample_label}.txt"

    txt_files = sorted(
        # coincidence_scan_run_ (plot_wfs_coincidence) or only_selection_scan_run_
        path_waveforms.glob(f"selection_cuts_*_scan_run_*_{txt_suffix}")
    )
    
    y_err_runs = {}
    runs_files = set()
    for txt_file in txt_files:
        match = re.search(r"selection_cuts_(?:coincidence|only_selection)_scan_run_(\d+)", txt_file.name)
        if match:
            run = int(match.group(1))
            runs_files.add((run, txt_file))

    for run in sorted(runs_files):
        with open(run[1], 'r') as f:
            text = f.read()
        matches = re.findall(r"Channel\s+(\d+):\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s+ADC",text)

        y_err_run = {int(channel): float(error) for channel, error in matches}
        y_err_runs[run[0]] = y_err_run
    return y_err_runs
