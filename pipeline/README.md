# pipeline

Runs coincidence → waveform selection → mean-waveform fit → light yield vs
field for one **cut set**,
on a reduced set of 7 fields (fast, for validating cuts) or on the full scan.
`TRIGGER=no_coinc` skips the coincidence (see below).

There are two cut sets, both editable templates that list every option
with its alternatives. They are identical except for `RUN_SET`:

```bash
pipeline/run_pipeline.sh workflow_fast             # 7 fields: 0 10 20 40 100 205 292 kV
pipeline/run_pipeline.sh workflow_all              # 22 fields, once the cuts are settled
python3 pipeline/compare_cutsets.py workflow_fast  # efficiency and fit summary
python3 pipeline/compare_cutsets.py --runs full workflow_all
```

To compare workflows, fits and light yields included, see
[`analysis/comparison/`](../analysis/comparison/README.md).

With the same settings both share one sample, so `workflow_all` only
processes the 15 runs `workflow_fast` did not. `--runs reduced|full`
overrides the file's `RUN_SET`. To try other choices, copy one of them to a
new name (the name labels the plots) and edit it.

The run sets live in [`pds/runs.py`](../pds/runs.py) (`REDUCED_FIELDS`,
`FIT_SCAN`). The reduced set has 4 fields at ≤ 40 kV, where most field
effects show, and always keeps 0 kV: the fit normalizes every field to the
E = 0 peak.

## Two names: cut set and sample tag

| Name | What it is | Example | Names |
|---|---|---|---|
| cut set | the recipe: file `cutsets/NAME.env` | `workflow_fast` | legends of `compare_cutsets.py` and the light-yield plot; recorded in the fit folder's `sample.txt` |
| sample tag | the data the recipe selects, every choice spelled out | `coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV_noise500_post2000_full10000` | `coincidence/selected_waveforms/TAG/`, and the fit and light yield made on it, `$PDS_OUTPUT/pipeline/TAG/RUNSET/` |
| coincidence tag | the sample tag without the waveform cuts | `coinc_M3-M4_vs_M5-M6_save_M7-M8_a0_r292kV` | `coincidence/saved_coincidences/TAG/` |

`pipeline/run_pipeline.sh NAME --print-tag` prints the sample tag
(`--print coinc-tag` the coincidence tag, `--print outputs` every output
folder of the cut set). Every run prints both names with
the tag in words, and writes them to `sample.txt` in the selection and fit
folders. The light-yield script labels each sample `cut set [tag]`;
`compare_cutsets.py` labels each fit `cut set, templates SET [tag]`, names
the template sets in the figure title and draws each set with its own line
style.

Reading a tag, part by part:

| Part | Cut-set variable | Example | Meaning |
|---|---|---|---|
| `coinc_` … `_vs_` … | `TRIGGER` (or `LEFT/RIGHT_CHANNELS`) | `coinc_M3-M4_vs_M5-M6` | coincidence: the trigger channels of one side vs the other (`default_coinc`, `inverse_coinc` and `custom_coinc` are written by their channels) |
| `no_coinc` | `TRIGGER=no_coinc` | `no_coinc` | no coincidence |
| `save_` | `TRIGGER` (or `SAVE_CHANNELS`), `CHANNELS` for `no_coinc` | `save_M7-M8`, `save_M1-2021`, `save_membrane` | the channels saved and analysed |
| `w` | `WINDOW_TICKS` | `w20` | coincidence window [ticks], only when not the standard 10 |
| `a` | `MIN_AMPLITUDE_ADC` | `a0`, `anone` | minimum trigger amplitude [ADC], or no amplitude cut (`false`) |
| `n` | `MAX_WAVEFORMS` | `n5000` | `no_coinc`, only when not 0 (all) |
| `r` | `RATE_THRESHOLDS` | `r292kV`, `rnone` | rate-threshold folder (`RateAnalysis_data_` dropped), or no rate cut |
| `iv-` | `INTERVALS` | `iv-xe` | only for a file other than `coincidence/waveform_intervals.ini` (`waveform_intervals_` dropped) |
| `noise`, `post` | `MAX_NOISE_ADC`, `MAX_POST_ADC` | `noise500_post2000` | noise-region and post-signal limits [ADC] |
| `aux` | `MAX_NOISE_ADC` = `MAX_POST_ADC` | `aux500` | both limits, when equal (the tag of the single `MAX_AUX_ADC` they replaced, so those samples keep their folders) |
| `full` | `MAX_FULL_RANGE_ADC` | `full10000` | full-waveform limit [ADC] |
| `peak` | `REQUIRE_PEAK` | `peak` | `no_coinc`, only when 1 |

Channels: a module with both arrays by name (2080 2081 → `M8`), other
channels by number, joined by `-`; `all`, `cathode` or `membrane` when the
list is exactly that set of the `INTERVALS` file. Decimals are written with
`p` (`aux250p5`). Not in the tag, on purpose:
`RUN_SET` (the fast and full passes share a sample), `MODULES`, `TEMPLATES`
and `LY_CHANNELS` (they only change the fit and light yield, which are kept
per cut set), and `CHANNELS_PER_PASS` (memory only). The tag names the
threshold and intervals files but cannot show their contents: each folder
keeps a settings snapshot with a checksum of them, and a folder made from
other contents is refused until `--force coincidence` / `--force selection`.

## Cut sets

One file per cut set in `cutsets/NAME.env`. `NAME` names the fit outputs;
the coincidence and selection folders are named by the tags, so two cut sets
with the same choices share them. Copy
[`cutsets/workflow_fast.env`](cutsets/workflow_fast.env) or
[`cutsets/workflow_all.env`](cutsets/workflow_all.env) and change it.

| Variable | Stage | Meaning |
|---|---|---|
| `RUN_SET` | all | `reduced` (default, 7 fields) or `full` (22 fields); `--runs` overrides |
| `TRIGGER` | all | which sample, see the table below |
| `LEFT_CHANNELS`, `RIGHT_CHANNELS`, `SAVE_CHANNELS` | coincidence | `custom_coinc` only: trigger channels and saved channels (numbers and/or `all`, `cathode`, `membrane`) |
| `WINDOW_TICKS` | coincidence | coincidence window |
| `MIN_AMPLITUDE_ADC` | coincidence | minimum amplitude on the trigger channels (keeps amplitude > value, so `0` still drops ≤ 0); `false` = no amplitude cut |
| `RATE_THRESHOLDS` | coincidence | rate-equalization threshold folder; empty = no rate cut |
| `INTERVALS` | both | INI with the per-channel windows and an optional `[peak_finder]` section |
| `MAX_NOISE_ADC` | selection | limit on max \|ADC − baseline\| over every tick of the noise region |
| `MAX_POST_ADC` | selection | post-signal amplitude limit |
| `MAX_FULL_RANGE_ADC` | selection | full-waveform amplitude limit |
| `MODULES` | fit | modules to fit; their channels must be saved (`default_coinc` → M7 M8, `inverse_coinc` → M5 M6) |
| `TEMPLATES` | fit | detector response: `large_pulse` (default), `francesca` or `lucca`, see below |
| `FIT_PROPAGATE` | fit | `1`: fit with propagated uncertainties (data, E=0 normalization, tick, template), as in `fitting_bertolini_avg.py --propagate-uncertainties`, written to `fit_<TEMPLATES>_propagated/`; default `0` |
| `LY_CHANNELS` | lightyield | channels averaged into the S/S0 curve; empty = the channels of `MODULES`, or every selected channel when `MODULES` is empty |

`TRIGGER` values (channels: Mk → 20k0 20k1, Ck → 10k0 10k1):

| `TRIGGER` | Trigger | Saved and analysed |
|---|---|---|
| `default_coinc` | M3+M4 (2030..2041) vs M5+M6 (2050..2061) | M7+M8 (2070..2081) |
| `inverse_coinc` | M7+M8 (2070..2081) vs M1+M2 (2010..2021) | M5+M6 (2050..2061) |
| `custom_coinc` | `LEFT_CHANNELS` vs `RIGHT_CHANNELS` | `SAVE_CHANNELS` |
| `no_coinc` | none | every waveform of `CHANNELS` |

A `custom_coinc` with the channels of one of the two standard layouts is
run as that layout, so it shares its folders.

Folders from the previous, hashed tags (`default_coinc_w10_a0_r_292kV_888e6582`)
are renamed by [`migrate_tags.sh`](migrate_tags.sh) without rerunning
anything; see its `--help`.

Peak-finder thresholds (used by the "peak outside the signal window" cuts)
go in the INI file; without the section the defaults are kept:

```ini
[peak_finder]
min_height_adc = 500     ; significant peak: height >= max(min_height_adc,
min_height_sigma = 10    ;                    min_height_sigma * noise RMS)
```

## Without coincidence (`TRIGGER=no_coinc`)

`TRIGGER=no_coinc` selects every waveform of `CHANNELS` with
[`bin/only_selection`](../coincidence/only_selection.cpp), for any channel in
the `INTERVALS` file, cathode (10xx) or membrane (20xx). It applies the same
quality cuts as `plot_wfs_coincidence`: the two programs share the cut code
in `coincidence_lib.cpp`. To see what the coincidence requirement changes,
copy `workflow_fast.env` to, say, `nocoinc_fast.env`, set `TRIGGER=no_coinc`
and `CHANNELS="2080 2081"`, and compare:

```bash
pipeline/run_pipeline.sh nocoinc_fast       # sample no_coinc_save_M8_r292kV_noise500_post2000_full10000
python3 pipeline/compare_cutsets.py workflow_fast nocoinc_fast
```

| Variable | Meaning |
|---|---|
| `CHANNELS` | channel numbers and/or `all`, `cathode`, `membrane` (expanded from the `[channel_NNNN]` sections of `INTERVALS`) |
| `MODULES` | modules to fit (M1-M8, C1-C8), each needing its channels in `CHANNELS`; may be empty: selection only, the cut flow is still copied for `compare_cutsets.py` |
| `RATE_THRESHOLDS` | same rate-equalization amplitude cut that `run_coincidence` applies to saved channels; empty = none |
| `INTERVALS`, `MAX_NOISE_ADC`, `MAX_POST_ADC`, `MAX_FULL_RANGE_ADC` | as in coincidence mode |
| `REQUIRE_PEAK` | `1` also rejects waveforms without a significant peak (default `0`, as in `plot_wfs_coincidence`) |
| `MAX_WAVEFORMS` | per channel and run, after the rate cut, in file order; `0` = all (default) |
| `CHANNELS_PER_PASS` | channels held in memory at once, one pass over the input per group (default 4; `0` = all) |

The coincidence stage is skipped. The files are labelled
`only_selection_scan_run_RUN_TAG`, so the fit,
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
  `coincidence_lib.cpp` for 1010-1081 and 2050-2081; other channels still get
  their `fprompt_*.csv` rows, with `fprompt` = `nan`, as the cut summary states.

## Caching

- The coincidence goes to `coincidence/saved_coincidences/COINC_TAG/` and
  the selection to `coincidence/selected_waveforms/SAMPLE_TAG/`. Cut sets
  that differ only in waveform cuts share the coincidence and get their own
  selection folders, so changing a cut never overwrites another sample.
- Each stage marks finished runs, so rerunning skips them, and `--runs full`
  after a reduced pass only processes the 15 new runs.
- Editing a cut set's choices gives a new tag, so a new folder; the old one
  stays. Only edits to the contents of the threshold or intervals file, which
  the tag cannot show, are refused until `--force coincidence` /
  `--force selection` (the fit and light yield follow automatically).
- The fit and light yield are named by the sample tag, like the selection,
  so every result traces back to `coincidence/selected_waveforms/TAG/`:
  the fit goes to `$PDS_OUTPUT/pipeline/TAG/RUN_SET/fit_TEMPLATES/` (it also
  depends on the template set), the light yield to
  `$PDS_OUTPUT/pipeline/TAG/RUN_SET/lightyield/`. Editing a cut set's
  waveform cuts therefore gives new fit folders too; the old ones stay.
- Cut sets giving the same tag share these folders. Each module fit
  (`plots_bertolini_avg/MODULE/.done`) and each `LY_CHANNELS` list
  (`lightyield/.done_chs_2080_2081`) is cached on its own, so a cut set
  fitting other modules or averaging other channels adds its results next
  to the others instead of replacing them. A result reruns by itself when
  the selection changed or gained runs; fits made on an older selection are
  cleared when the cut flow is copied again.
- Results of the previous layout, `$PDS_OUTPUT/pipeline/CUTSET/RUN_SET/`,
  move to the tag folders with `pipeline/migrate_fit_folders.sh` (try
  `--dry-run` first). Nothing is refitted: the markers are converted.
- `--force coincidence,selection,fit,lightyield` redoes any stage; `--stages` runs a subset;
  `--dry-run` prints the commands.

## Outputs

| Path | Contents |
|---|---|
| `coincidence/selected_waveforms/TAG/selection_cuts_*.txt` | cut flow per run |
| `coincidence/selected_waveforms/TAG/pipeline_selection_settings.txt`, `sample.txt` | what the folder was selected from; the tag in words |
| `coincidence/selected_waveforms/TAG/mean_median_waveforms_*.png` | mean, median, 16–84 % band |
| `coincidence/selected_waveforms/TAG/channel_<ch>_*.csv` | mean waveform per channel and run |
| `coincidence/selected_waveforms/TAG/fprompt_*.csv` | one row per final-selection waveform, see below |
| `coincidence/selected_waveforms/TAG/all_waveforms_*_{from_coincidence,before_cuts,final_selection}.png` | waveform density before and after the cuts |
| `$PDS_OUTPUT/pipeline/TAG/RUNSET/fit_TEMPLATES/plots_bertolini_avg/MODULE/` | fit plots and `parameters/*.txt` |
| `$PDS_OUTPUT/pipeline/TAG/RUNSET/fit_TEMPLATES/selection/` | cut flow the fit was made on |
| `$PDS_OUTPUT/pipeline/TAG/RUNSET/fit_TEMPLATES/sample.txt`, `cutset.env` | sample tag spelled out, selection folder, templates; the cut set of the last fit and a copy of it |
| `$PDS_OUTPUT/pipeline/TAG/RUNSET/lightyield/fit_LY_wo_template_chs_*.{png,txt}` | S/S0 vs field, Birks fit, and the numbers behind the figure, per channel list |
| `$PDS_OUTPUT/pipeline/compare/RUNSET/` | `compare_cutsets.py` figures and efficiency table |

`fprompt_<ch>_<label>.csv` columns, one row per waveform that passed the cuts
(written by `plot_wfs_coincidence` and `only_selection`; the first five are
the original ones and stay first):

| Column | Meaning |
|---|---|
| `run`, `event`, `channel`, `waveform_index_save` | the waveform in the ROOT `WaveformTree` |
| `fprompt` | prompt fraction; `nan` for channels without a SiPM type |
| `timestamp` | raw DAQ timestamp [16 ns ticks] |
| `baseline` | median of the `noise` interval, as subtracted for the mean waveform |
| `integral_50_500` | trapezoid of ADC − baseline over samples [50, 500), the window of `pds/integrals.py` (`INTEGRAL_FIRST_SAMPLE`, `INTEGRAL_LAST_SAMPLE`, mirrored in `coincidence_lib.hpp`) |
| `amplitude` | max(ADC − baseline) in the `signal` interval [ADC] |
| `pulse_start` | pulse start [ticks] |
| `multiplicity` | coincidence mode: rows of the coincidence CSV naming this waveform (1 for `run_coincidence` output); the mean waveform counts the waveform this many times, so weight averages by it. Always 1 for `no_coinc` |
| `minimum_timestamp_coinc`, `channel_coincident_left`, `waveform_index_coincident_left`, `channel_coincident_right`, `waveform_index_coincident_right` | coincidence mode only: the coincidence that selected the waveform (the first CSV row when multiplicity > 1) |

The multiplicity-weighted mean of `integral_50_500` equals the integral of the
mean waveform in `channel_<ch>_*.csv` up to float32 rounding.

The fit runs in batch mode (no interactive Minuit windows). Set `PYTHON` to an
interpreter with `iminuit` and `dunestyle`, e.g.
`PYTHON=.venv/bin/python pipeline/run_pipeline.sh workflow_fast`.

## Light yield vs field

The `lightyield` stage runs
[`analysis/LY_vs_EF/fit_LY_wo_template.py`](../analysis/LY_vs_EF/fit_LY_wo_template.py)
on the selection: the integral of each run's mean waveform, normalized to
0 kV (run 039510, so every channel in `LY_CHANNELS` needs it), averaged over
the channels, with a Birks fit and the PD-HD and previous-M8 points. Only the
runs of the run set are used, although the selection folder may hold more.

```bash
pipeline/run_pipeline.sh workflow_fast --stages lightyield   # selection already done
pipeline/run_pipeline.sh workflow_fast --stages selection,fit,lightyield
```

Run by hand, the script takes cut-set names or tags directly:

```bash
python analysis/LY_vs_EF/fit_LY_wo_template.py workflow_fast --channels 2080 2081 --batch
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
| `lucca` | `reference/spe_templates/lucca/` | M8 (run 039366, variant 9C) |

The fit window and t0 limits were tuned on M5, M6 and M8 with the francesca
templates (M8 with `lucca` has its own: 4.5 µs, t0 in [0.84, 1.04] µs); the other modules use a 3 µs window and t0 in [0.9, 1.4] µs.
On the reduced default_coinc sample (`workflow_fast`), M8 gives τ_eff(0) = 1445 ns with
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
