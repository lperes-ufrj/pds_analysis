# comparison

Compares pipeline workflows (cut sets run by
[`pipeline/run_pipeline.sh`](../../pipeline/README.md)): what differs in
their settings, how many waveforms pass the cuts, the τ fits, and the light
yield vs field.

```bash
python analysis/comparison/compare_workflows.py workflow_fast my_variation
python analysis/comparison/compare_workflows.py workflow_fast:reduced workflow_all:full
python analysis/comparison/compare_workflows.py workflow_fast my_variation --modules M8 --name aux_study
```

Each workflow is a cut-set name with outputs in `$PDS_OUTPUT/pipeline/NAME/`.
Its run set is the one after `:`, else the `RUN_SET` of its cut-set file. Run
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

- Settings come from the `cutset.env` copied at fit time, so they describe
  the results even if the cut-set file was edited or deleted since.
- The light yield is the newest `lightyield/fit_LY_wo_template_chs_*.txt` of
  each workflow; its file name is listed in `summary.txt`.
- The ratio errors combine the two workflows' errors as independent. Two
  workflows that share most waveforms are correlated, so for them the error
  bars are too large.
