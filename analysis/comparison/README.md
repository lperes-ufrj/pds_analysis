# comparison

Compares pipeline workflows (cut sets run by
[`pipeline/run_pipeline.sh`](../../pipeline/README.md)): what differs in
their settings, how many waveforms pass the cuts, the τ fits, and the light
yield vs field.

```bash
python analysis/comparison/compare_workflows.py          # asks which samples to include
python analysis/comparison/compare_workflows.py workflow_fast my_variation
python analysis/comparison/compare_workflows.py workflow_fast:reduced workflow_all:full
python analysis/comparison/compare_workflows.py workflow_fast my_variation --modules M8 --name aux_study
python analysis/comparison/compare_workflows.py $PDS_OUTPUT/pipeline/TAG/reduced/fit_large_pulse workflow_fast
```

Without arguments it scans `coincidence/selected_waveforms/` and asks, tag by
tag, whether to include each fit made on it (one per run set and template
set): `y`, `n` (default), `a` (all the
rest) or `q` (stop asking), then the output folder name. Selections with no
fit yet are listed but not offered; to add one, make a cut set that gives its
tag (`pipeline/run_pipeline.sh CUTSET --print tag`) and run its `fit` and
`lightyield` stages.

Each workflow is a cut-set name, read from the folders the pipeline names
for its sample tag, `$PDS_OUTPUT/pipeline/TAG/RUNSET/fit_TEMPLATES/` and
`.../lightyield/` (`pipeline/run_pipeline.sh NAME --print outputs`), or the
path of a fit folder. Its run set is the one after `:`, else the `RUN_SET`
of its cut-set file. Run
the `fit` and `lightyield` stages of each workflow first; anything missing is
reported and skipped. The first workflow is the reference of the ratio panel.
Up to 8 workflows, one colour and marker each, in a fixed order.

Output, in `$PDS_OUTPUT/analysis/comparison/NAME/` (`NAME` = the workflows
joined by `_vs_`, or `--name`):

| File | Contents |
|---|---|
| `summary.txt` | sample tags; the cut-set settings that differ; selection efficiency per run; τ_s per field and module; Birks parameters and S/S0 per field |
| `fit_MODULE.png` | τ_s, A_s, A_f, I_f/I_tot, I_tot/I_tot(0) and χ²/ndf vs field, overlaid |
| `lightyield.png` | S/S0 vs field with each workflow's Birks curve and the PD-HD and previous-M8 points, and below the ratio to the reference workflow |

Notes:

- Every label names the template set of the fit: `CUTSET (RUNSET, TEMPLATES)`.
  `summary.txt` has a `templates` line, `DIFFER` when the workflows use
  different sets, the figure titles list the sets, and in `fit_MODULE.png`
  each set has its own line style (solid, dashed, dotted, dash-dot). The
  light yield uses no template: workflows that differ only in templates
  show the same light-yield points.
- Settings come from the `cutset.env` copied at fit time, so they describe
  the results even if the cut-set file was edited or deleted since.
- The light yield is the newest `lightyield/fit_LY_wo_template_chs_*.txt` of
  each workflow's `LY_CHANNELS` (any channel list for a fit folder given by
  path); its file name is listed in `summary.txt`.
- The ratio errors combine the two workflows' errors as independent. Two
  workflows that share most waveforms are correlated, so for them the error
  bars are too large.
