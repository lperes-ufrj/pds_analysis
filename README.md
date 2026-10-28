# pds_analysis

Waveform analysis for the ProtoDUNE-VD (PD-VD) photon detection system:
decoding, X-ARAPUCA SPE calibration, coincidence selection, deconvolution,
scintillation-profile fits and light-yield studies.

This repository is the reorganized successor of `sag_analysis`. It keeps the
full commit history of the code but none of the data (CSV scans, plots, NumPy
products, binaries) that used to be committed. See
[Migrating from sag_analysis](#migrating-from-sag_analysis).

## Layout

The folders follow the order of the analysis:

```
pds_analysis/
├── pds/             shared Python library (paths, runs, waveform tools, SPE templates, integrals)
├── decoding/        step 0: raw data -> gallery ROOT files
│   ├── gallery/        interactive gallery macros + local decoder jobscript
│   ├── grid/           justIN jobscripts, submit_*.sh, sub_jobs.py
│   │   └── tarball/    files shipped to the grid (gallery_pdvddaphne.C, fcl)
│   └── env/            FNAL environment setup (source set_all.sh from here)
├── calibration/     step 1: SPE calibration (read_waveforms C++ + main.py)
├── coincidence/     step 2: coincidence selection (C++ run_coincidence, plot_wfs_coincidence)
│   └── input_lists/    one ROOT-file path per line, per run
├── deconvolution/   step 3: SPE / large-pulse deconvolution
├── fit/             step 4: fits of the deconvolved waveforms vs field
│   └── waveform_fits/  template-convolved fits (Bertolini, Xe transfer, toy MC)
├── analysis/        step 5: rate equalization, LY vs E-field, LY vs Xe ppm,
│                    charge-based evaluation, fit comparisons
├── pipeline/        coincidence -> selection -> fit per cut set, reduced (7 fields) or full scan
├── reference/       small, tracked reference inputs
│   ├── spe_templates/francesca/   external SPE templates (txt)
│   └── large_pulse_templates/     large-pulse templates + cuts used
└── archive/         superseded code kept for reference (legacy coincidence)
```

Each stage has its own README with details: [calibration](calibration/README.md),
[coincidence](coincidence/README.md), [deconvolution](deconvolution/README.md),
[fit](fit/README.md), [charge evaluation](analysis/EvalSelectionWithCharge/README.md).

## Data and outputs

Nothing generated is committed. Two environment variables decide where the
data goes; both default to folders inside the repository that git ignores:

| Variable | Default | Content |
|---|---|---|
| `PDS_DATA` | `<repo>/data` | ROOT inputs: `roots/np02vd_raw_run*_gallery.root`, `roots/metrics_*`, `roots/physics/...` |
| `PDS_OUTPUT` | `<repo>/output` | everything the stages write: `calibration/`, `deconvolution/`, `fit/`, `analysis/` |

The coincidence executables keep writing to `coincidence/saved_coincidences/`
and `coincidence/selected_waveforms/` (also ignored). Rate-equalization
thresholds (`analysis/RateAnalysis_data*/equalized_run_*_thresholds.txt`) are
small and stay tracked; their `.npz` companions are not.

On the FNAL machines a typical setup is:

```bash
export PDS_DATA=/exp/dune/data/users/$USER/pds_analysis
export PDS_OUTPUT=/exp/dune/data/users/$USER/pds_analysis/output
```

All Python paths are resolved in [`pds/paths.py`](pds/paths.py). Use it
instead of hard-coding locations in new scripts.

## Installation

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e .                 # numpy, scipy, matplotlib, pandas, iminuit, uproot, awkward
pip install "git+https://github.com/DUNE/dune_plot_style.git"   # dunestyle, used by the plots
```

Also needed for some steps:

- **ROOT with PyROOT** for `analysis/rate_analysis.py` and `deconvolution/filter_large_pulses.py`.
- **A C++17 compiler, Make and `root-config`** for `calibration/` and `coincidence/`.
- **DUNE software, gallery and FNAL data access** for `decoding/`.

The scripts also run without `pip install -e .`, because each one adds the
repository root to `sys.path`.

## Running the pipeline

### 0. Decoding (FNAL)

```bash
cd decoding/env && source set_all.sh   # builds the grid tarball from ../grid/tarball and uploads it
cd ../grid/jobs && ./submit_single_run.sh ...
```

The gallery macro `decoding/grid/tarball/gallery_pdvddaphne.C` writes a
`WaveformTree` with one entry per waveform (`run`, `subrun`, `event`,
`waveform_index`, `channel`, `timestamp`, `nsamples`, `adc`).

### 1. SPE calibration

```bash
make -C calibration
(cd calibration && ./read_waveforms)    # asks for run and module; reads $PDS_DATA/roots/
python3 calibration/main.py             # fingerplot -> multigauss -> SPE template
```

Templates go to `$PDS_OUTPUT/calibration/data/templates/<run>/template_<ch>.npy`.

### 2. Rate equalization and coincidences

```bash
python3 analysis/rate_analysis.py coincidence/input_lists/input_run041523.txt --reference-sample
python3 analysis/rate_analysis.py coincidence/input_lists/input_run039510.txt \
  --reference-npz analysis/RateAnalysis_data_292kV/reference_run_041523.npz

make -C coincidence
./bin/run_coincidence coincidence/input_lists/input_run039510.txt \
  --run 039510 --timestamp example_039510 \
  --config coincidence/waveform_intervals.ini \
  --channels-coincident-left 2030 2031 2040 2041 \
  --channels-coincident-right 2050 2051 2060 2061 \
  --channels-to-save 2070 2071 2080 2081 \
  --window-ticks 10 --min-amplitude-adc 0
./bin/plot_wfs_coincidence --config coincidence/waveform_intervals.ini \
  --csv coincidence/saved_coincidences/example_039510/coincidence_scan_run_039510_example_039510.csv \
  --output-dir coincidence/selected_waveforms/example_039510 \
  coincidence/input_lists/input_run039510.txt

# batches
bash coincidence/run_coincidences.sh my_batch
bash coincidence/run_plot_wfs_all.sh my_batch
```

### 3. Deconvolution

```bash
python3 deconvolution/deconvolve_coincidence.py <csv> [mine|francesca]
python3 deconvolution/all_electric_field.py         # every field of a ramp
python3 deconvolution/filter_large_pulses.py <coincident_waveforms.root>
```

### 4. Fits

```bash
python3 fit/all_electric_field.py [template] [column]
python3 fit/fit_vs_field.py [template]
python3 fit/waveform_fits/fitting_bertolini_avg.py   # template-convolved fit per field
```

### Steps 2-4 in one go, per cut set

[`pipeline/run_pipeline.sh`](pipeline/README.md) chains coincidence, waveform
selection and the template-convolved fit for a cut set defined in
`pipeline/cutsets/*.env`, on 7 fields (`--runs reduced`, default) or on the
full scan (`--runs full`). `pipeline/compare_cutsets.py` overlays the results.

```bash
pipeline/run_pipeline.sh baseline
python3 pipeline/compare_cutsets.py baseline tight_aux
```

### 5. Physics analyses

```bash
python3 analysis/LY_vs_EF/fit_LY.py
python3 analysis/LY_vs_Xeppm/plot_LY_vs_Xeppm.py
python3 analysis/fit_comparison/plot_module_comparison.py
```

## Migrating from sag_analysis

`sag_analysis` itself is unchanged. To move data you already have, copy it
into the new locations:

| sag_analysis | pds_analysis |
|---|---|
| `calib/aux/*.py`, `src/src.py` | `pds/*.py`, `pds/integrals.py` (`from pds import paths`, `from pds.integrals import ...`) |
| `calib/` | `calibration/` |
| `calib/roots/` | `$PDS_DATA/roots/` |
| `calib/output/` | `$PDS_OUTPUT/calibration/` |
| `calib/output/data/templates/francesca_template/` | `reference/spe_templates/francesca/` |
| `deconvolve/` (+ `deconvolve/output/`) | `deconvolution/` (+ `$PDS_OUTPUT/deconvolution/`) |
| `filter/filter.py`, `filter/templates_large_pulses/` | `deconvolution/filter_large_pulses.py`, `reference/large_pulse_templates/` |
| `physics_fit/` (+ `fit/output/`) | `fit/` (+ `$PDS_OUTPUT/fit/`) |
| `wf_fit/fitting-*.py` (+ `wf_fit/plots_*`) | `fit/waveform_fits/fitting_*.py` (+ `$PDS_OUTPUT/fit/waveform_fits/`) |
| `physics/` | `analysis/fit_comparison/` |
| `selection/`, `dir_to_tar/`, `jobs_justin/`, `set_fnal_env/` | `decoding/gallery/`, `decoding/grid/tarball/`, `decoding/grid/`, `decoding/env/` |
| `coincidence/legacy_coincidence/` | `archive/legacy_coincidence/` |
| `all_eletric_field.py` | `all_electric_field.py` |

## Conventions

- **Code only in git.** Data and outputs go to `$PDS_DATA` / `$PDS_OUTPUT`. If a
  small file is a real input (a template, a threshold table), put it in `reference/`.
- **Shared code goes in `pds/`.** Don't copy functions between scripts; import them.
- **Branches + pull requests** instead of committing straight to `main`.
- **Commit prefix**: `[ADD]`, `[EDIT]`, `[FIX]`, `[REORGANIZE]`, `[DOCS]`.
- **Notebooks** are for exploration. Clear large outputs before committing.

## Known issues (carried over)

- `fit/waveform_fits/fitting_bertolini{,_avg,_mine,_rise}.py` are near-copies
  (~1000 lines each). They should become one script with options.
- `analysis/LY_vs_Xeppm/fit_LY_Xe.py` uses names that are never defined
  (`run_to_efield`, `PD_HD_result`, ...); see `ruff check .`.
- Several scripts still have fixed run lists, channels and sample identifiers
  at the top. Review them before processing a new sample.
