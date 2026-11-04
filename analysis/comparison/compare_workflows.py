"""Compare pipeline workflows (cut sets): settings, selection efficiency,
tau fits and light yield vs field.

Usage:
    python analysis/comparison/compare_workflows.py WORKFLOW[:RUNSET] [...]
        [--modules M8,M5] [--name NAME] [--out DIR]

    WORKFLOW   a cut-set name, i.e. a folder $PDS_OUTPUT/pipeline/WORKFLOW/
               filled by pipeline/run_pipeline.sh. Its run set is the one
               after ':' (workflow_fast:full), else RUN_SET of its cut-set
               file, else the only run-set folder it has.
               The first workflow is the reference of the ratio panels.
    --modules  modules to compare (default: every fitted module)
    --name     output folder name (default: the workflows joined by _vs_)
    --out      output folder (default $PDS_OUTPUT/analysis/comparison/NAME/)

Reads, per workflow ($PDS_OUTPUT/pipeline/WORKFLOW/RUNSET/):
    cutset.env, sample.txt                      settings at fit time, sample tag
    selection/selection_cuts_*.txt              cut flow -> selection efficiency
    plots_bertolini_avg/MODULE/parameters/      fit parameters and integrals
    lightyield/fit_LY_wo_template_chs_*.txt     newest S/S0 table and Birks fit
Writes:
    summary.txt         settings that differ, sample tags, efficiency, tau_s,
                        Birks parameters and S/S0 per field
    fit_MODULE.png      fit parameters and integrals vs field, overlaid
    lightyield.png      S/S0 vs field with Birks curves, and the ratio to the
                        reference workflow
"""
import argparse
import re
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_DIR))
sys.path.insert(0, str(REPO_DIR / "pipeline"))
sys.path.insert(0, str(REPO_DIR / "analysis" / "LY_vs_EF"))

import matplotlib  # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

import compare_cutsets as cc  # noqa: E402  (fit tables, efficiency, panels)
import fit_LY_wo_template as ly  # noqa: E402  (Birks model, PD-HD and M8 references)
from pds import paths  # noqa: E402
from pds.runs import FIT_SCAN, RUN_SETS  # noqa: E402

# Categorical slots in fixed order (one per workflow, never cycled), each
# with its own marker so identity never rests on colour alone.
COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100",
          "#e87ba4", "#008300", "#6250d6", "#e34948"]
MARKERS = ["o", "s", "^", "D", "v", "P", "X", "*"]
REFERENCE_GRAY = "#8a8a85"

PIPELINE_DIR = paths.OUTPUT_DIR / "pipeline"
SETTING_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)=(.*)$")
BIRKS_RE = re.compile(r"B_1 = (\S+) \+- (\S+), k = (\S+) \+- (\S+), chi2/ndof = (\S+)/(\d+)")


class Workflow:
    def __init__(self, spec):
        self.name, _, runs = spec.partition(":")
        self.base = PIPELINE_DIR / self.name
        if not self.base.is_dir():
            raise SystemExit(f"no pipeline output for workflow {self.name!r} in {PIPELINE_DIR}")
        self.runs = runs or self._default_runs()
        if self.runs not in RUN_SETS:
            raise SystemExit(f"{spec}: run set must be one of {', '.join(RUN_SETS)}")
        self.dir = self.base / self.runs
        if not self.dir.is_dir():
            raise SystemExit(f"{spec}: {self.dir} does not exist; run the pipeline with this run set")
        self.settings = self._settings()
        self.tag = cc.sample_tag(self.name, self.runs) or "?"

    def _default_runs(self):
        cutset_file = REPO_DIR / "pipeline" / "cutsets" / f"{self.name}.env"
        if cutset_file.is_file():
            value = read_settings(cutset_file).get("RUN_SET")
            if value:
                return value
        present = [d.name for d in self.base.iterdir() if d.name in RUN_SETS]
        if len(present) == 1:
            return present[0]
        return "reduced"

    def _settings(self):
        # the copy made at fit time describes these results; the cut-set file
        # may have been edited (or deleted) since
        for path in (self.dir / "cutset.env",
                     REPO_DIR / "pipeline" / "cutsets" / f"{self.name}.env"):
            if path.is_file():
                return read_settings(path)
        return {}

    @property
    def label(self):
        return f"{self.name} ({self.runs})"


def read_settings(path):
    """KEY=VALUE lines of a cut-set file, comments and quotes stripped."""
    settings = {}
    for line in Path(path).read_text().splitlines():
        match = SETTING_RE.match(line)
        if not match:
            continue
        value = match.group(2)
        if value.startswith('"'):
            value = value[1:value.find('"', 1)]
        else:
            value = value.split("#")[0].strip()
        settings[match.group(1)] = value
    return settings


def read_lightyield(workflow):
    """Newest light-yield table of the workflow, or None:
    {file, channels, birks: (B1, B1_err, k, k_err, chi2, ndof), efield, y, lo, up}."""
    files = sorted((workflow.dir / "lightyield").glob("fit_LY_wo_template_chs_*.txt"),
                   key=lambda p: p.stat().st_mtime)
    if not files:
        return None
    path = files[-1]
    text = path.read_text()
    channels = re.search(r"^# channels: (.*)$", text, re.M)
    birks = BIRKS_RE.search(text)
    data = np.loadtxt(path, comments="#", skiprows=1, ndmin=2)
    return {
        "file": path,
        "channels": channels.group(1) if channels else "?",
        "birks": tuple(float(v) for v in birks.groups()) if birks else None,
        "efield": data[:, 0], "y": data[:, 1], "lo": data[:, 2], "up": data[:, 3],
    }


def style(i):
    return {"color": COLORS[i], "marker": MARKERS[i], "ms": 6,
            "mec": "white", "mew": 0.8, "capsize": 2, "lw": 1.5}


def offset(x, i, n, step=0.006):
    """Small horizontal offset so overlapping points stay visible."""
    return np.asarray(x) * (1 + step * (i - (n - 1) / 2))


# ------------------------------------------------------------------- sections
def settings_section(workflows):
    keys = sorted({k for w in workflows for k in w.settings})
    differing = [k for k in keys if len({w.settings.get(k, "-") for w in workflows}) > 1]
    lines = ["== workflows"]
    for w in workflows:
        lines.append(f"  {w.label:<28} sample {w.tag}")
    lines.append("")
    if len(workflows) < 2:
        return lines
    lines.append("== settings that differ" if differing else "== settings: all equal")
    width = max([len(k) for k in differing] + [8])
    for k in differing:
        lines.append(f"  {k:<{width}}  " + "  |  ".join(
            f"{w.name}: {w.settings.get(k, '(unset)') or '(empty)'}" for w in workflows))
    same = [k for k in keys if k not in differing]
    if same and differing:
        lines.append(f"  (equal: {', '.join(same)})")
    lines.append("")
    return lines


def efficiency_section(workflows):
    runs = [(kv, run) for kv, run in FIT_SCAN.items()
            if any(run in RUN_SETS[w.runs].values() for w in workflows)]
    lines = ["== fraction of waveforms passing all waveform cuts (summed over saved channels)",
             f"  {'HV_kV':>6} {'run':>7} " + " ".join(f"{w.name:>24}" for w in workflows)]
    for kv, run in runs:
        cells = []
        for w in workflows:
            eff = cc.efficiency(w.name, w.runs, run) if run in RUN_SETS[w.runs].values() else None
            cells.append("-" if eff is None or eff[1] == 0
                         else f"{eff[0] / eff[1]:.3f} ({eff[0]}/{eff[1]})")
        lines.append(f"  {kv:>6} {run:>7} " + " ".join(f"{c:>24}" for c in cells))
    lines.append("")
    return lines


def fit_section(workflows, modules, out_dir):
    lines = []
    for module in modules:
        tables = {i: cc.fit_tables(w.name, w.runs, module) for i, w in enumerate(workflows)}
        for i, t in tables.items():
            if t is None:
                print(f"[missing] {module} fit of {workflows[i].label}")
        tables = {i: t for i, t in tables.items() if t is not None}
        if not tables:
            continue

        fig, axes = plt.subplots(2, 3, figsize=(15, 8), sharex=True)
        for ax, (table, column, label) in zip(axes.flat, cc.PANELS):
            for i, t in tables.items():
                df = t[table]
                err = df[f"{column}_err"] if f"{column}_err" in df else None
                ax.errorbar(offset(df["efield_kVcm"], i, len(workflows)), df[column],
                            yerr=err, label=workflows[i].label, **style(i))
            ax.set_ylabel(label)
            ax.grid(alpha=0.3)
        for ax in axes[-1]:
            ax.set_xlabel("Electric field [kV/cm]")
        axes.flat[0].legend(fontsize=9)
        fig.suptitle(f"{module}: workflow comparison")
        fig.tight_layout()
        path = out_dir / f"fit_{module}.png"
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"figure: {path}")

        # tau_s per field, side by side
        lines.append(f"== {module}: tau_slow [us] per field (valid = Minuit converged)")
        lines.append(f"  {'HV_kV':>6} {'E_kVcm':>7} " + " ".join(f"{workflows[i].name:>24}" for i in tables))
        fields = sorted({kv for t in tables.values() for kv in t["params"]["field_kV"]})
        for kv in fields:
            cells, efield = [], None
            for t in tables.values():
                row = t["params"][t["params"]["field_kV"] == kv]
                if row.empty:
                    cells.append("-")
                    continue
                row = row.iloc[0]
                efield = row["efield_kVcm"]
                flag = "" if int(row["valid"]) else " !"
                cells.append(f"{row['tau_slow']:.4f} +- {row['tau_slow_err']:.4f}{flag}")
            lines.append(f"  {kv:>6g} {efield:>7.3f} " + " ".join(f"{c:>24}" for c in cells))
        lines.append("")
    return lines


def lightyield_section(workflows, out_dir):
    results = {}
    for i, w in enumerate(workflows):
        result = read_lightyield(w)
        if result is None:
            print(f"[missing] light yield of {w.label}; run its lightyield stage")
        else:
            results[i] = result
    if not results:
        return ["== light yield: none found", ""]

    lines = ["== light yield: Birks fit S/S0 = 1 - B_1 E/(E + k)"]
    for i, r in results.items():
        if r["birks"]:
            b1, b1e, k, ke, chi2, ndof = r["birks"]
            fit = f"B_1 = {b1:.4f} +- {b1e:.4f}, k = {k:.4f} +- {ke:.4f}, chi2/ndof = {chi2:.2f}/{int(ndof)}"
        else:
            fit = "no Birks fit in the table"
        lines.append(f"  {workflows[i].label:<28} channels {r['channels']}: {fit}")
        lines.append(f"  {'':<28} {r['file'].name}")

    ref_i = min(results)
    ref = results[ref_i]
    fig, (top, bottom) = plt.subplots(
        2, 1, figsize=(8, 7.5), sharex=True, gridspec_kw={"height_ratios": [3, 1.3]})
    top.errorbar(ly.E, ly.PD_HD_result, yerr=[ly.PD_HD_err_low, ly.PD_HD_err_high],
                 fmt="s", ms=4, color=REFERENCE_GRAY, mfc="none", capsize=1,
                 label="PD-HD data", zorder=1)
    top.scatter(ly.efield_previous, ly.relative_s1_previous, marker="x",
                color=REFERENCE_GRAY, label="M8 previous study", zorder=1)
    x_fit = np.linspace(0, 0.9, 200)
    n = len(workflows)
    for i, r in results.items():
        st = style(i)
        top.errorbar(offset(r["efield"], i, n), r["y"], yerr=[r["lo"], r["up"]],
                     fmt=st.pop("marker"), label=workflows[i].label, ls="none", **st)
        if r["birks"]:
            top.plot(x_fit, ly.Birks(x_fit, r["birks"][0], r["birks"][2]),
                     color=COLORS[i], ls="--", lw=1.5)

        # ratio to the reference at the fields both have; errors combined as
        # independent (too large when the two share waveforms, which
        # correlates them)
        common = [j for j, e in enumerate(r["efield"]) if np.any(np.isclose(ref["efield"], e))]
        if i == ref_i or not common:
            continue
        e = r["efield"][common]
        jref = [int(np.argmin(np.abs(ref["efield"] - v))) for v in e]
        y, y0 = r["y"][common], ref["y"][jref]
        sig = lambda lo, up: 0.5 * (lo + up)  # noqa: E731
        ratio = y / y0
        err = ratio * np.hypot(sig(r["lo"][common], r["up"][common]) / y,
                               sig(ref["lo"][jref], ref["up"][jref]) / y0)
        st = style(i)
        bottom.errorbar(offset(e, i, n), ratio, yerr=err, fmt=st.pop("marker"), ls="none", **st)

    top.set_ylabel(r"$S/S_0$ (LY normalized)")
    top.set_ylim(0.3, 1.2)
    top.grid(alpha=0.3)
    top.legend(loc="lower left", fontsize=8, frameon=True)
    top.set_title("Light yield vs field: workflow comparison", fontsize=11)
    bottom.axhline(1, color=COLORS[ref_i], lw=1.5)
    bottom.set_ylabel(f"ratio to\n{workflows[ref_i].name}", fontsize=9)
    bottom.set_xlabel("Electric field (kV/cm)")
    bottom.grid(alpha=0.3)
    fig.tight_layout()
    path = out_dir / "lightyield.png"
    fig.savefig(path, dpi=200)
    plt.close(fig)
    print(f"figure: {path}")

    # S/S0 per field, side by side
    efields = sorted({round(float(e), 6) for r in results.values() for e in r["efield"]})
    lines.append("")
    lines.append("  S/S0 per field (-err/+err)")
    lines.append(f"  {'E_kVcm':>7} " + " ".join(f"{workflows[i].name:>24}" for i in results))
    for e in efields:
        cells = []
        for r in results.values():
            j = np.flatnonzero(np.isclose(r["efield"], e))
            cells.append("-" if j.size == 0 else
                         f"{r['y'][j[0]]:.4f} -{r['lo'][j[0]]:.4f}/+{r['up'][j[0]]:.4f}")
        lines.append(f"  {e:>7.3f} " + " ".join(f"{c:>24}" for c in cells))
    lines.append("")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("workflows", nargs="+", help="WORKFLOW or WORKFLOW:RUNSET")
    parser.add_argument("--modules", default=None, help="comma list; default: every fitted module")
    parser.add_argument("--name", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    workflows = [Workflow(spec) for spec in args.workflows]
    if len(workflows) > len(COLORS):
        raise SystemExit(f"at most {len(COLORS)} workflows per comparison (one colour each)")
    labels = [w.label for w in workflows]
    if len(set(labels)) != len(labels):
        raise SystemExit("the same workflow and run set is given twice")

    names = [w.name if [v.name for v in workflows].count(w.name) == 1 else f"{w.name}-{w.runs}"
             for w in workflows]
    out_dir = Path(args.out) if args.out else (
        paths.OUTPUT_DIR / "analysis" / "comparison" / (args.name or "_vs_".join(names)))
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.modules:
        modules = args.modules.split(",")
    else:
        modules = sorted({p.parent.name for w in workflows
                          for p in (w.dir / "plots_bertolini_avg").glob("*/parameters/")})

    lines = settings_section(workflows) + efficiency_section(workflows)
    lines += fit_section(workflows, modules, out_dir) if modules else ["== fits: none found", ""]
    lines += lightyield_section(workflows, out_dir)

    summary = "\n".join(lines)
    print("\n" + summary)
    (out_dir / "summary.txt").write_text(summary + "\n")
    print(f"summary: {out_dir / 'summary.txt'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
