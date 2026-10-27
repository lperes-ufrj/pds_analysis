"""Repository path anchors.

All input/output paths derive from the location of this file, not from the
cwd: the runners can be called from anywhere (python deconvolution/deconvolve.py
or cd deconvolution && python deconvolve.py).

Large inputs and every generated output live outside git:

    PDS_DATA    (default <repo>/data)     ROOT inputs, e.g. data/roots/...
    PDS_OUTPUT  (default <repo>/output)   plots and data written by each stage

Coincidence products stay where the coincidence/ executables write them
(coincidence/selected_waveforms, coincidence/saved_coincidences; git-ignored).
"""
import os
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]

DATA_DIR   = Path(os.environ.get("PDS_DATA", REPO_ROOT / "data")).expanduser()
OUTPUT_DIR = Path(os.environ.get("PDS_OUTPUT", REPO_ROOT / "output")).expanduser()

# inputs (not tracked)
ROOTS_DIR       = DATA_DIR / "roots"
COINC_DIR       = REPO_ROOT / "coincidence" / "selected_waveforms"
SAVED_COINC_DIR = REPO_ROOT / "coincidence" / "saved_coincidences"
RATE_DIR        = REPO_ROOT / "analysis" / "RateAnalysis_data_292kV"

# small reference inputs (tracked)
REFERENCE_DIR            = REPO_ROOT / "reference"
FRANCESCA_TEMPLATE_DIR   = REFERENCE_DIR / "spe_templates" / "francesca"
LARGE_PULSE_TEMPLATE_DIR = REFERENCE_DIR / "large_pulse_templates"

# outputs, one folder per stage
CALIB_DIR  = OUTPUT_DIR / "calibration"
DECONV_DIR = OUTPUT_DIR / "deconvolution"
FIT_DIR    = OUTPUT_DIR / "fit"

# SPE templates written by calibration/main.py, read by the later stages
TEMPLATES_DIR = CALIB_DIR / "data" / "templates"


def add_repo_to_path():
    """Allow 'import pds...' when running any script directly."""
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))


def out(stage_dir, kind, *parts):
    """<stage_dir>/<kind>/<parts...>, creating the directories.

    kind: "plots" or "data".
    """
    p = Path(stage_dir) / kind
    for part in parts:
        p = p / str(part)
    p.mkdir(parents=True, exist_ok=True)
    return p


def save_waveform_txt(path, wf):
    """One value per line, %.9e -- same format as the templates in
    reference/large_pulse_templates/."""
    np.savetxt(path, np.asarray(wf), fmt="%.9e")
    return path


def load_waveform_txt(path):
    return np.loadtxt(path)
