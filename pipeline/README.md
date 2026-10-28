# pipeline

Runs coincidence → waveform selection → mean-waveform fit for one **cut set**,
on a reduced set of 7 fields (fast, for validating cuts) or on the full scan.
`TRIGGER=no_coinc` skips the coincidence (see below).

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

## Two names: cut set and sample tag

| Name | What it is | Example | Names |
|---|---|---|---|
| cut set | the recipe: file `cutsets/NAME.env` | `baseline_m8`, `single_m8` | fit folder `$PDS_OUTPUT/pipeline/NAME/RUNSET/`, legends of `compare_cutsets.py` |
| sample tag | the data the recipe selects | `default_coinc_w10_a0_r_292kV_888e6582`, `no_coinc_2080-2081_r_292kV_6eea14cf` | `coincidence/saved_coincidences/TAG/`, `coincidence/selected_waveforms/TAG/` |

Reading a tag: first the `TRIGGER` value; then, for a coincidence, `w10` the
window in ticks and `a0` the minimum amplitude in ADC, or for `no_coinc` the
channels; `r_292kV` the rate-threshold folder (`rnorate`: none); and a hash
of all the settings that define the sample. Every run prints both names with the
tag spelled out, and writes them to `sample.txt` in the selection and fit
folders. Cut sets that differ only in waveform cuts, `MODULES` or
`TEMPLATES` share a tag and its selection folder, which is why the fits are
named by cut set. The light-yield script and `compare_cutsets.py` label each
sample `cut set [tag]`.

## Cut sets

One file per cut set in `cutsets/NAME.env`. `NAME` names the fit outputs; the
coincidence and selection folders are named by the coincidence tag
(`pipeline/run_pipeline.sh NAME --print-tag`), so one label identifies a
sample everywhere, as with the older `YYYYMMDD_HHMMSS` rounds.
Copy [`cutsets/baseline.env`](cutsets/baseline.env) (the production settings) and change it.

| Variable | Stage | Meaning |
|---|---|---|
| `TRIGGER` | all | which sample, see the table below |
| `LEFT_CHANNELS`, `RIGHT_CHANNELS`, `SAVE_CHANNELS` | coincidence | `custom_coinc` only: trigger channels and saved channels (numbers and/or `all`, `cathode`, `membrane`) |
| `WINDOW_TICKS` | coincidence | coincidence window |
| `MIN_AMPLITUDE_ADC` | coincidence | minimum amplitude on the trigger channels |
| `RATE_THRESHOLDS` | coincidence | rate-equalization threshold folder; empty = no rate cut |
| `INTERVALS` | both | INI with the per-channel windows and an optional `[peak_finder]` section |
| `MAX_AUX_ADC` | selection | noise and post-signal amplitude limit |
| `MAX_FULL_RANGE_ADC` | selection | full-waveform amplitude limit |
| `MODULES` | fit | modules to fit; their channels must be saved (`default_coinc` → M7 M8, `inverse_coinc` → M5 M6) |
| `TEMPLATES` | fit | detector response: `large_pulse` (default) or `francesca`, see below |

`TRIGGER` values (channels: Mk → 20k0 20k1, Ck → 10k0 10k1):

| `TRIGGER` | Trigger | Saved and analysed |
|---|---|---|
| `default_coinc` | M3+M4 (2030..2041) vs M5+M6 (2050..2061) | M7+M8 (2070..2081) |
| `inverse_coinc` | M7+M8 (2070..2081) vs M1+M2 (2010..2021) | M5+M6 (2050..2061) |
| `custom_coinc` | `LEFT_CHANNELS` vs `RIGHT_CHANNELS` | `SAVE_CHANNELS` |
| `no_coinc` | none | every waveform of `CHANNELS` |

A `custom_coinc` with the channels of one of the two standard layouts is
run as that layout, so it shares its folders. These names replace `m8`,
`low` and `MODE=single`; [`migrate_tags.sh`](migrate_tags.sh) renames old
output folders (`c_m8_` → `default_coinc_`, `c_low_` → `inverse_coinc_`,
`s_` → `no_coinc_`). The hashes are unchanged, so nothing reruns.

Peak-finder thresholds (used by the "peak outside the signal window" cuts)
go in the INI file; without the section the defaults are kept:

```ini
[peak_finder]
min_height_adc = 500     ; significant peak: height >= max(min_height_adc,
min_height_sigma = 10    ;                    min_height_sigma * noise RMS)
```

## Without coincidence (`TRIGGER=no_coinc`)

[`cutsets/single_m8.env`](cutsets/single_m8.env) selects every waveform of
`CHANNELS` with [`bin/only_selection`](../coincidence/only_selection.cpp),
for any channel in the `INTERVALS` file, cathode (10xx) or membrane (20xx);
[`single_cathode.env`](cutsets/single_cathode.env) and
[`single_membrane.env`](cutsets/single_membrane.env) take all of each. It
selects them applying the same quality cuts as `plot_wfs_coincidence`: the two programs
share the cut code in `coincidence_lib.cpp`. Compare it with `baseline_m8` to
see what the coincidence requirement changes:

```bash
pipeline/run_pipeline.sh single_m8
python3 pipeline/compare_cutsets.py baseline_m8 single_m8
python analysis/LY_vs_EF/fit_LY_wo_template.py single_m8 --channels 2080 2081 --batch
```

| Variable | Meaning |
|---|---|
| `CHANNELS` | channel numbers and/or `all`, `cathode`, `membrane` (expanded from the `[channel_NNNN]` sections of `INTERVALS`) |
| `MODULES` | modules to fit (M1-M8, C1-C8), each needing its channels in `CHANNELS`; may be empty: selection only, the cut flow is still copied for `compare_cutsets.py` |
| `RATE_THRESHOLDS` | same rate-equalization amplitude cut that `run_coincidence` applies to saved channels; empty = none |
| `INTERVALS`, `MAX_AUX_ADC`, `MAX_FULL_RANGE_ADC` | as in coincidence mode |
| `REQUIRE_PEAK` | `1` also rejects waveforms without a significant peak (default `0`, as in `plot_wfs_coincidence`) |
| `MAX_WAVEFORMS` | per channel and run, after the rate cut, in file order; `0` = all (default) |
| `CHANNELS_PER_PASS` | channels held in memory at once, one pass over the input per group (default 4; `0` = all) |

The coincidence stage is skipped. The tag is `no_coinc_<channels>[_n<MAX_WAVEFORMS>]_r<rate>_<hash>`,
where `<channels>` is the keyword, the channels joined by `-` (up to 4), or `<n>ch`,
and the files are labelled `only_selection_scan_run_RUN_TAG`, so the fit,
`compare_cutsets.py`, the light-yield script and `pds/integrals.py` read them
like the coincidence ones. The efficiency in `compare_cutsets.py` is relative
to the waveforms entering the quality cuts, after the rate cut.

Selected waveforms are held in memory for the median and percentiles:
about 2 kB each, so around 300 MB per channel and run at the M8 rates. Hence
`CHANNELS_PER_PASS`; `MAX_WAVEFORMS` caps the count. With more than one group
the multi-panel figure is written per group,
`mean_median_waveforms_LABEL_ch<group>.png`. The before-cuts density plot
shows the first 20000 waveforms per channel.

Caveats:

- The rate-threshold files have no row for 2020, 2030, 2031 and 2041, so
  with `RATE_THRESHOLDS` set those channels are skipped in every run but the
  reference (041523, no file); the driver prints a note. Their light yield
  then fails for lack of a 0 kV point. Set `RATE_THRESHOLDS=` to keep them.
- The prompt fraction needs the channel's SiPM type, listed in
  `coincidence_lib.cpp` for 1010-1081 and 2050-2081; other channels get no
  `fprompt_*.csv`, as the cut summary states.

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
| `coincidence/selected_waveforms/TAG/all_waveforms_*_{from_coincidence,before_cuts,final_selection}.png` | waveform density before and after the cuts |
| `$PDS_OUTPUT/pipeline/NAME/RUNSET/plots_bertolini_avg/MODULE/` | fit plots and `parameters/*.txt` |
| `$PDS_OUTPUT/pipeline/NAME/RUNSET/selection/` | cut flow the fit was made on |
| `$PDS_OUTPUT/pipeline/NAME/RUNSET/sample.txt` | cut set, sample tag spelled out, templates |
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

Figure and table go to `$PDS_OUTPUT/analysis/LY_vs_EF/CUTSET__TAG/` (or
`.../TAG/` when you pass a tag).

## Fit templates

The fit convolves the scintillation model with each module's response
template ([`pds/modules.py`](../pds/modules.py); `python3 -m pds.modules
--templates SET` lists modules and channels). Channels follow the LArSoft
map: Mk → 20k0 20k1, Ck → 10k0 10k1.

| `TEMPLATES` | Folder | Modules |
|---|---|---|
| `large_pulse` (default) | `reference/large_pulse_templates/` | M1-M8, C1-C8; M2 only array 2, so it is fitted on 2021 alone |
| `francesca` | `reference/spe_templates/francesca/` | M5-M8 |

The fit window and t0 limits were tuned on M5, M6 and M8 with the francesca
templates; the other modules use a 3 µs window and t0 in [0.9, 1.4] µs.
On the reduced baseline_m8 sample, M8 gives τ_eff(0) = 1445 ns with
large_pulse against 1386 ns with francesca. M7 does not fit with either set
(τ_s at its 0.7 µs limit, χ²/ndf in the thousands), so the M7 mean waveform
itself needs a look. A module whose fit fails does not stop the others, but
the fit stage then exits with an error. Changing `TEMPLATES` refits the cut
set into the same folder.

## Caveat on the fit

`fitting_bertolini_avg.py` keeps t0 within ±0.6 sample of 1.008 µs (M5, M8).
In a synthetic test, a one-sample offset between the data and the template
convention pushed τ_s from 1.3 µs to its 1.6 µs limit. If τ_s sits at a limit
for a cut set, check t0 before blaming the cut.
