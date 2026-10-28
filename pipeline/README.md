# pipeline

Runs coincidence → waveform selection → mean-waveform fit for one **cut set**,
on a reduced set of 7 fields (fast, for validating cuts) or on the full scan.

```bash
pipeline/run_pipeline.sh baseline                  # 7 fields: 0 10 20 40 100 205 292 kV
pipeline/run_pipeline.sh tight_aux                 # a variation
python3 pipeline/compare_cutsets.py baseline tight_aux
pipeline/run_pipeline.sh baseline --runs full      # once the cuts are settled
```

The run sets live in [`pds/runs.py`](../pds/runs.py) (`REDUCED_FIELDS`,
`FIT_SCAN`). The reduced set has 4 fields at ≤ 40 kV, where most field
effects show, and always keeps 0 kV: the fit normalizes every field to the
E = 0 peak.

## Cut sets

One file per cut set in `cutsets/NAME.env`. `NAME` names the fit outputs; the
coincidence and selection folders are named by the coincidence tag
(`pipeline/run_pipeline.sh NAME --print-tag`), so one label identifies a
sample everywhere, as with the older `YYYYMMDD_HHMMSS` rounds.
Copy [`cutsets/baseline.env`](cutsets/baseline.env) (the production settings) and change it.

| Variable | Stage | Meaning |
|---|---|---|
| `TRIGGER` | coincidence | `low`: trigger 2070-2081 vs 2010-2021, saves M5+M6. `m8`: trigger 2030-2041 vs 2050-2061, saves M7+M8 |
| `WINDOW_TICKS` | coincidence | coincidence window |
| `MIN_AMPLITUDE_ADC` | coincidence | minimum amplitude on the trigger channels |
| `RATE_THRESHOLDS` | coincidence | rate-equalization threshold folder; empty = no rate cut |
| `INTERVALS` | both | INI with the per-channel windows and an optional `[peak_finder]` section |
| `MAX_AUX_ADC` | selection | noise and post-signal amplitude limit |
| `MAX_FULL_RANGE_ADC` | selection | full-waveform amplitude limit |
| `MODULES` | fit | modules to fit; must be saved by `TRIGGER` (`low` → M5 M6, `m8` → M8) |

Peak-finder thresholds (used by the "peak outside the signal window" cuts)
go in the INI file; without the section the defaults are kept:

```ini
[peak_finder]
min_height_adc = 500     ; significant peak: height >= max(min_height_adc,
min_height_sigma = 10    ;                    min_height_sigma * noise RMS)
```

## Caching

- **Coincidence** output goes to `coincidence/saved_coincidences/c_<trigger>_w.._a.._r.._<hash>/`,
  and the selection to `coincidence/selected_waveforms/` under the same tag.
  The tag is derived from the coincidence settings, so cut sets that differ
  only in waveform cuts share one coincidence pass **and one selection
  folder**. The folder holds one selection at a time: switching to another
  such cut set needs `--force selection`, which replaces the files there.
  Fits are kept per cut set, each with a copy of the cut flow it used, and
  fitting is refused while the folder holds another cut set's selection.
- Each stage marks finished runs, so rerunning skips them, and `--runs full`
  after a reduced pass only processes the 15 new runs.
- Editing a cut set's waveform cuts after its selection ran is refused until
  you pass `--force selection` (the fit follows automatically).
- `--force coincidence,selection,fit` redoes any stage; `--stages` runs a subset;
  `--dry-run` prints the commands.

## Outputs

| Path | Contents |
|---|---|
| `coincidence/selected_waveforms/TAG/selection_cuts_*.txt` | cut flow per run |
| `coincidence/selected_waveforms/TAG/mean_median_waveforms_*.png` | mean, median, 16–84 % band |
| `coincidence/selected_waveforms/TAG/channel_<ch>_*.csv` | mean waveform per channel and run |
| `coincidence/selected_waveforms/TAG/fprompt_*.csv` | prompt fraction per waveform |
| `$PDS_OUTPUT/pipeline/NAME/RUNSET/plots_bertolini_avg/MODULE/` | fit plots and `parameters/*.txt` |
| `$PDS_OUTPUT/pipeline/NAME/RUNSET/selection/` | cut flow the fit was made on |
| `$PDS_OUTPUT/pipeline/compare/RUNSET/` | `compare_cutsets.py` figures and efficiency table |

The fit runs in batch mode (no interactive Minuit windows). Set `PYTHON` to an
interpreter with `iminuit` and `dunestyle`, e.g.
`PYTHON=.venv/bin/python pipeline/run_pipeline.sh baseline`.

## Light yield vs field

[`analysis/LY_vs_EF/fit_LY_wo_template.py`](../analysis/LY_vs_EF/fit_LY_wo_template.py)
takes cut-set names or tags directly:

```bash
python analysis/LY_vs_EF/fit_LY_wo_template.py baseline_m8 --channels 2080 2081 --batch
```

Figure and table go to `$PDS_OUTPUT/analysis/LY_vs_EF/<samples>/`.

## Caveat on the fit

`fitting_bertolini_avg.py` keeps t0 within ±0.6 sample of 1.008 µs (M5, M8).
In a synthetic test, a one-sample offset between the data and the template
convention pushed τ_s from 1.3 µs to its 1.6 µs limit. If τ_s sits at a limit
for a cut set, check t0 before blaming the cut.
