"""Compare pipeline workflows (cut sets): settings, selection efficiency,
tau fits and light yield vs field.

Usage:
    python analysis/comparison/compare_workflows.py [WORKFLOW[:RUNSET] ...]
        [--modules M8,M5] [--name NAME] [--out DIR]

    Without WORKFLOW: scans coincidence/selected_waveforms/ and asks, tag by
    tag, whether to include the fit made on it (y/n, a = all the rest,
    q = stop asking); selections without a fit are listed, not offered.

    WORKFLOW   a cut-set name (pipeline/cutsets/NAME.env), read from the
               folders pipeline/run_pipeline.sh names for its sample tag:
               $PDS_OUTPUT/pipeline/TAG/RUNSET/{fit_TEMPLATES,lightyield}/.
               Its run set is the one after ':' (workflow_fast:full), else
               RUN_SET of its cut-set file. Or the path of a fit folder
               $PDS_OUTPUT/pipeline/TAG/RUNSET/fit_TEMPLATES/.
               The first workflow is the reference of the ratio panels.
    --modules  modules to compare (default: every fitted module)
    --name     output folder name (default: the workflows joined by _vs_)
    --out      output folder (default $PDS_OUTPUT/analysis/comparison/NAME/)

Reads, per workflow ($PDS_OUTPUT/pipeline/TAG/RUNSET/):
    fit_TEMPLATES/cutset.env, sample.txt        settings at fit time, sample tag
    fit_TEMPLATES/selection/selection_cuts_*.txt
                                                cut flow -> selection efficiency
    fit_TEMPLATES/plots_bertolini_avg/MODULE/parameters/
                                                fit parameters and integrals
    lightyield/fit_LY_wo_template_chs_*.txt     newest S/S0 table and Birks fit
                                                (of the cut set's LY_CHANNELS)
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
SELECTED_DIR = REPO_DIR / "coincidence" / "selected_waveforms"
SETTING_RE = re.compile(r"^\s*([A-Z][A-Z0-9_]*)=(.*)$")
BIRKS_RE = re.compile(r"B_1 = (\S+) \+- (\S+), k = (\S+) \+- (\S+), chi2/ndof = (\S+)/(\d+)")


class Workflow:
    def __init__(self, spec):
        path = Path(spec)
        if path.is_dir():  # a fit folder: pipeline/TAG/RUNSET/fit_TEMPLATES
            self.dir = path.resolve()
            self.name = cc.read_sample(self.dir, "cut set") or self.dir.parent.parent.name
            self.runs = self.dir.parent.name
            self.ly_channels = None  # any: the newest table
            cutset_file = None
        else:
            name, _, runs = spec.partition(":")
            if runs and runs not in RUN_SETS:
                raise SystemExit(f"{spec}: run set must be one of {', '.join(RUN_SETS)}")
            outputs = cc.cutset_outputs(name, runs or None)
            self.dir = Path(outputs["fit_dir"])
            self.name, self.runs = outputs["cutset"], outputs["run_set"]
            self.ly_channels = outputs["lightyield_channels"]
            cutset_file = Path(name) if Path(name).is_file() else (
                REPO_DIR / "pipeline" / "cutsets" / f"{self.name}.env")
        if self.runs not in RUN_SETS:
            raise SystemExit(f"{spec}: {self.dir} is not in a run-set folder ({', '.join(RUN_SETS)})")
        self.ly_dir = self.dir.parent / "lightyield"
        if not (self.dir.is_dir() or self.ly_dir.is_dir()):
            raise SystemExit(f"{spec}: no fit or light yield in {self.dir.parent}; run the "
                             f"pipeline's fit and lightyield stages with this run set")
        self.templates = cc.templates(self.dir) or "?"
        self.settings = self._settings(cutset_file)
        self.tag = cc.sample_tag(self.dir) or self.dir.parent.parent.name
        self.label = f"{self.name} ({self.runs}, {self.templates})"

    def _settings(self, cutset_file):
        # the copy made at fit time describes these results; the cut-set file
        # may have been edited (or deleted) since
        for path in (self.dir / "cutset.env", cutset_file):
            if path and path.is_file():
                return read_settings(path)
        return {}


def scan_fits():
    """{sample tag: [fit folder, ...]} of the fits in PIPELINE_DIR."""
    fits = {}
    for info in sorted(PIPELINE_DIR.glob("*/*/fit_*/sample.txt")):
        if info.parent.parent.name not in RUN_SETS:
            continue
        tag = cc.sample_tag(info.parent)
        if tag:
            fits.setdefault(tag, []).append(str(info.parent))
    return fits


def ask_workflows():
    """Ask, tag by tag, which fits to compare; returns WORKFLOW:RUNSET specs."""
    if not sys.stdin.isatty():
        raise SystemExit("no workflows given, and no terminal to ask on")
    fits = scan_fits()
    selected = {d.name for d in SELECTED_DIR.iterdir() if d.is_dir()} if SELECTED_DIR.is_dir() else set()
    offered = [(tag, spec) for tag in sorted(selected | set(fits)) for spec in fits.get(tag, [])]
    unfitted = sorted(selected - set(fits))
    if not offered:
        raise SystemExit(f"no fits in {PIPELINE_DIR}; run the pipeline's fit and lightyield stages first")

    print(f"{len(offered)} fitted sample(s). The first one you include is the reference of the ratios.")
    print("Answer y / n (default) / a = include all the rest / q = stop asking.\n")
    chosen, take_rest = [], False
    for i, (tag, spec) in enumerate(offered, 1):
        fit_dir = Path(spec)
        name = cc.read_sample(fit_dir, "cut set") or "?"
        runs, templates = fit_dir.parent.name, re.sub(r"^fit_", "", fit_dir.name)
        if not take_rest:
            print(f"[{i}/{len(offered)}] {tag}")
            answer = ""
            while True:
                answer = input(f"        fit {runs}, templates {templates}, last made by cut set {name}."
                               " Include? [y/N/a/q] ").strip().lower()
                if answer in ("", "y", "n", "a", "q"):
                    break
                print("        please answer y, n, a or q")
            if answer == "q":
                break
            take_rest = answer == "a"
            if answer not in ("y", "a"):
                continue
        chosen.append(spec)
        if len(chosen) == len(COLORS):
            print(f"(at most {len(COLORS)} workflows per comparison: stopping here)")
            break

    if unfitted:
        print("\nSelections without a fit (not offered): " + ", ".join(unfitted))
        print("  To include one, make a cut set giving that tag (pipeline/run_pipeline.sh"
              " CUTSET --print tag)\n  and run its stages: --stages fit,lightyield")
    if not chosen:
        raise SystemExit("nothing chosen")
    print("\nComparing:\n  " + "\n  ".join(chosen) + "\n")
    return chosen


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
    """Newest light-yield table of the workflow (of its LY_CHANNELS when it is
    a cut set: the folder may hold other channel lists), or None:
    {file, channels, birks: (B1, B1_err, k, k_err, chi2, ndof), efield, y, lo, up}."""
    channels = r"\d+(?:_\d+)*" if workflow.ly_channels is None else "_".join(workflow.ly_channels.split())
    name_re = re.compile(rf"fit_LY_wo_template_chs_{channels}_\d{{8}}_\d{{6}}\.txt")
    files = sorted((p for p in workflow.ly_dir.glob("fit_LY_wo_template_chs_*.txt")
                    if name_re.fullmatch(p.name)),
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


def column_width(workflows, minimum=24):
    """Table columns are headed by the labels (cut set, run set, templates)."""
    return max([minimum] + [len(w.label) for w in workflows])


def templates_lines(workflows):
    """The template set of each fit, flagged when they differ."""
    sets = list(dict.fromkeys(w.templates for w in workflows))
    if len(sets) == 1:
        return [f"== templates: {sets[0]} (every workflow)", ""]
    width = max(len(w.label) for w in workflows)
    lines = [f"== templates DIFFER: {' vs '.join(sets)} "
             "(fit line styles: " + ", ".join(
                 f"{t} {name}" for t, name in zip(sets, ["solid", "dashed", "dotted", "dash-dot"] * 2))
             + ")"]
    lines += [f"  {w.label:<{width}}  {w.templates}" for w in workflows]
    lines.append("")
    return lines


def offset(x, i, n, step=0.006):
    """Small horizontal offset so overlapping points stay visible."""
    return np.asarray(x) * (1 + step * (i - (n - 1) / 2))


# ------------------------------------------------------------------- sections
def settings_section(workflows):
    keys = sorted({k for w in workflows for k in w.settings})
    differing = [k for k in keys if len({w.settings.get(k, "-") for w in workflows}) > 1]
    lines = ["== workflows"]
    width = column_width(workflows, 28)
    for w in workflows:
        lines.append(f"  {w.label:<{width}} sample {w.tag}")
    lines.append("")
    lines += templates_lines(workflows)
    if len(workflows) < 2:
        return lines
    lines.append("== settings that differ" if differing else "== settings: all equal")
    width = max([len(k) for k in differing] + [8])
    for k in differing:
        lines.append(f"  {k:<{width}}  " + "  |  ".join(
            f"{w.label}: {w.settings.get(k, '(unset)') or '(empty)'}" for w in workflows))
    same = [k for k in keys if k not in differing]
    if same and differing:
        lines.append(f"  (equal: {', '.join(same)})")
    lines.append("")
    return lines


def efficiency_section(workflows):
    runs = [(kv, run) for kv, run in FIT_SCAN.items()
            if any(run in RUN_SETS[w.runs].values() for w in workflows)]
    width = column_width(workflows)
    lines = ["== fraction of waveforms passing all waveform cuts (summed over saved channels;"
             " the templates do not change it)",
             f"  {'HV_kV':>6} {'run':>7} " + " ".join(f"{w.label:>{width}}" for w in workflows)]
    for kv, run in runs:
        cells = []
        for w in workflows:
            eff = cc.efficiency(w.dir, run) if run in RUN_SETS[w.runs].values() else None
            cells.append("-" if eff is None or eff[1] == 0
                         else f"{eff[0] / eff[1]:.3f} ({eff[0]}/{eff[1]})")
        lines.append(f"  {kv:>6} {run:>7} " + " ".join(f"{c:>{width}}" for c in cells))
    lines.append("")
    return lines


def fit_section(workflows, modules, out_dir):
    lines = []
    for module in modules:
        tables = {i: cc.fit_tables(w.dir, module) for i, w in enumerate(workflows)}
        for i, t in tables.items():
            if t is None:
                print(f"[missing] {module} fit of {workflows[i].label}")
        tables = {i: t for i, t in tables.items() if t is not None}
        if not tables:
            continue

        fitted = [workflows[i] for i in tables]
        linestyles = cc.template_linestyles(w.dir for w in fitted)
        fig, axes = plt.subplots(2, 3, figsize=(15, 8), sharex=True)
        for ax, (table, column, label) in zip(axes.flat, cc.PANELS):
            for i, t in tables.items():
                df = t[table]
                err = df[f"{column}_err"] if f"{column}_err" in df else None
                ax.errorbar(offset(df["efield_kVcm"], i, len(workflows)), df[column],
                            yerr=err, label=workflows[i].label,
                            ls=linestyles[workflows[i].templates], **style(i))
            ax.set_ylabel(label)
            ax.grid(alpha=0.3)
        for ax in axes[-1]:
            ax.set_xlabel("Electric field [kV/cm]")
        axes.flat[0].legend(fontsize=9)
        fig.suptitle(f"{module}: workflow comparison ({cc.templates_title(w.dir for w in fitted)})")
        fig.tight_layout()
        path = out_dir / f"fit_{module}.png"
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"figure: {path}")

        # tau_s per field, side by side
        width = column_width(fitted)
        lines.append(f"== {module}: tau_slow [us] per field (valid = Minuit converged;"
                     f" {cc.templates_title(w.dir for w in fitted)})")
        lines.append(f"  {'HV_kV':>6} {'E_kVcm':>7} " + " ".join(f"{w.label:>{width}}" for w in fitted))
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
            lines.append(f"  {kv:>6g} {efield:>7.3f} " + " ".join(f"{c:>{width}}" for c in cells))
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
    if len({workflows[i].templates for i in results}) > 1:
        lines.append("  (no template enters the light yield, the integral of the mean waveforms:"
                     " workflows that differ only in templates show the same points)")
    width = column_width([workflows[i] for i in results], 28)
    for i, r in results.items():
        if r["birks"]:
            b1, b1e, k, ke, chi2, ndof = r["birks"]
            fit = f"B_1 = {b1:.4f} +- {b1e:.4f}, k = {k:.4f} +- {ke:.4f}, chi2/ndof = {chi2:.2f}/{int(ndof)}"
        else:
            fit = "no Birks fit in the table"
        lines.append(f"  {workflows[i].label:<{width}} channels {r['channels']}: {fit}")
        lines.append(f"  {'':<{width}} {r['file'].name}")

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
    width = column_width([workflows[i] for i in results])
    lines.append(f"  {'E_kVcm':>7} " + " ".join(f"{workflows[i].label:>{width}}" for i in results))
    for e in efields:
        cells = []
        for r in results.values():
            j = np.flatnonzero(np.isclose(r["efield"], e))
            cells.append("-" if j.size == 0 else
                         f"{r['y'][j[0]]:.4f} -{r['lo'][j[0]]:.4f}/+{r['up'][j[0]]:.4f}")
        lines.append(f"  {e:>7.3f} " + " ".join(f"{c:>{width}}" for c in cells))
    lines.append("")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("workflows", nargs="*",
                        help="WORKFLOW or WORKFLOW:RUNSET (none: choose interactively)")
    parser.add_argument("--modules", default=None, help="comma list; default: every fitted module")
    parser.add_argument("--name", default=None)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    asked = not args.workflows
    workflows = [Workflow(spec) for spec in (args.workflows or ask_workflows())]
    if len(workflows) > len(COLORS):
        raise SystemExit(f"at most {len(COLORS)} workflows per comparison (one colour each)")
    if len({w.dir for w in workflows}) != len(workflows):
        raise SystemExit("the same fit (workflow and run set) is given twice")

    names = [w.name if [v.name for v in workflows].count(w.name) == 1
             else f"{w.name}-{w.runs}-{w.templates}" for w in workflows]
    name = args.name or "_vs_".join(names)
    if asked and not (args.name or args.out):
        name = input(f"Output folder name [{name}]: ").strip() or name
    out_dir = Path(args.out) if args.out else paths.OUTPUT_DIR / "analysis" / "comparison" / name
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
