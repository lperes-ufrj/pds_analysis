"""Compare cut sets processed by pipeline/run_pipeline.sh.

For each module it overlays the fit parameters and the light integrals of
every cut set against the electric field, and prints the selection
efficiency (waveforms surviving all waveform cuts) per run and cut set.
Every label names the template set of the fit, and each template set has
its own line style in the figures (solid, dashed, dotted, dash-dot).

Usage:
    python pipeline/compare_cutsets.py CUTSET [CUTSET ...] [--runs reduced|full]
                                       [--modules M5,M6] [--out DIR]

    CUTSET   a cut-set name (pipeline/cutsets/NAME.env), whose fit folder is
             the one run_pipeline.sh names for its sample tag, run set and
             template set; or the path of a fit folder
             ($PDS_OUTPUT/pipeline/<tag>/<runs>/fit_<templates>/)

Reads, per fit folder ($PDS_OUTPUT/pipeline/<tag>/<runs>/fit_<templates>/):
    plots_bertolini_avg/<module>/parameters/
    selection/selection_cuts_*.txt
        (the cut flow copied at fit time; the selection folder itself may
        have been replaced since)
Writes (default $PDS_OUTPUT/pipeline/compare/<runs>/):
    compare_<module>_<cutsets>.png
    efficiency_<cutsets>.txt
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from pds import paths  # noqa: E402
from pds.runs import run_set  # noqa: E402


# (table, column, axis label); the error column is <column>_err
PANELS = [
    ("params", "tau_slow", r"$\tau_s$ [us]"),
    ("params", "Aslow", r"$A_s$ [a.u.]"),
    ("params", "Afast", r"$A_f$ [a.u.]"),
    ("integrals", "f_fast", r"$I_f / I_{tot}$"),
    ("integrals", "r_total", r"$I_{tot} / I_{tot}(E=0)$"),
    ("params", "chi2_ndof", r"$\chi^2$/ndf"),
]

COMBINED_RE = re.compile(r"^All cuts combined\s+(\d+)\s+(\d+)", re.M)
PIPELINE_SH = Path(__file__).resolve().parent / "run_pipeline.sh"


def read_table(path):
    return pd.read_csv(path, sep=r"\s+", comment="#")


def cutset_outputs(cutset, runs=None):
    """The folders run_pipeline.sh gives a cut set (its --print outputs):
    {"cutset", "tag", "run_set", "templates", "modules", "selection_dir",
    "fit_dir", "lightyield_dir", "lightyield_channels"}; runs=None takes the
    cut set's RUN_SET."""
    command = [str(PIPELINE_SH), cutset, "--print", "outputs"]
    if runs:
        command += ["--runs", runs]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stderr.strip() or f"{' '.join(command)} failed")
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def read_sample(fit_dir, field):
    """A field of the sample.txt the fit stage wrote ("cut set", "sample
    tag"), or None."""
    path = Path(fit_dir) / "sample.txt"
    if not path.is_file():
        return None
    match = re.search(rf"^{field}\s*: (\S+)", path.read_text(), re.M)
    return match.group(1) if match else None


def sample_tag(fit_dir):
    """Sample tag the folder was fitted on, or None."""
    return read_sample(fit_dir, "sample tag")


def resolve(spec, runs):
    """(name, fit folder) of a cut-set name or a fit-folder path; the name of
    a folder is the cut set of its last fit."""
    path = Path(spec)
    if path.is_dir():
        return read_sample(path, "cut set") or path.name, path
    outputs = cutset_outputs(spec, runs)
    return outputs["cutset"], Path(outputs["fit_dir"])


def templates(fit_dir):
    """Template set of a fit folder (fit_<templates>), or None."""
    fit_dir = Path(fit_dir)
    if fit_dir.name.startswith("fit_"):
        return fit_dir.name[len("fit_"):]
    path = fit_dir / "sample.txt"
    match = re.search(r"\(templates (\S+)\)", path.read_text()) if path.is_file() else None
    return match.group(1) if match else None


# line style per template set, in order of first appearance
TEMPLATE_LINESTYLES = ["-", "--", ":", "-."]


def template_linestyles(fit_dirs):
    """{template set: line style} of these fit folders."""
    order = list(dict.fromkeys(templates(d) or "?" for d in fit_dirs))
    return {t: TEMPLATE_LINESTYLES[i % len(TEMPLATE_LINESTYLES)] for i, t in enumerate(order)}


def templates_title(fit_dirs):
    """'templates large_pulse' when all are equal, else
    'templates large_pulse vs lucca'."""
    return "templates " + " vs ".join(template_linestyles(fit_dirs))


def display_name(name, fit_dir):
    tag = sample_tag(fit_dir)
    label = f"{name}, templates {templates(fit_dir) or '?'}"
    return f"{label} [{tag}]" if tag else label


def fit_tables(fit_dir, module):
    folder = Path(fit_dir) / "plots_bertolini_avg" / module / "parameters"
    params = folder / "fit_params_vs_field.txt"
    integrals = folder / "integrals_vs_field.txt"
    if not (params.is_file() and integrals.is_file()):
        return None
    return {"params": read_table(params), "integrals": read_table(integrals)}


def efficiency(fit_dir, run):
    """(accepted, total) summed over the saved channels, or None."""
    folder = Path(fit_dir) / "selection"
    tag = sample_tag(fit_dir)
    files = sorted(folder.glob(f"selection_cuts_*_run_{run}_{tag or '*'}.txt"))
    if not files:
        return None
    match = COMBINED_RE.search(files[0].read_text())
    if not match:
        return None
    accepted, rejected = int(match.group(1)), int(match.group(2))
    return accepted, accepted + rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("cutsets", nargs="+")
    parser.add_argument("--runs", default="reduced", choices=("reduced", "full"))
    parser.add_argument("--modules", default=None,
                        help="comma list; default: every module found")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    out_dir = Path(args.out) if args.out else paths.out(
        paths.OUTPUT_DIR / "pipeline", "compare", args.runs)
    out_dir.mkdir(parents=True, exist_ok=True)
    fits, names = {}, {}  # key (unique, for file names) -> fit folder, cut-set name
    for spec in args.cutsets:
        name, fit_dir = resolve(spec, args.runs)
        if any(fit_dir.resolve() == d.resolve() for d in fits.values()):
            raise SystemExit(f"{spec}: the same fit folder is given twice ({fit_dir})")
        key = name
        if key in fits:  # two fits of one cut set: other templates
            key = f"{name}-{templates(fit_dir) or fit_dir.name}"
        fits[key], names[key] = fit_dir, name
    for name, fit_dir in fits.items():
        if not fit_dir.is_dir():
            print(f"[missing] cut set {name}: no fit folder {fit_dir}")
    stem = "_vs_".join(fits)

    # ---- selection efficiency per run (the templates do not change it)
    lines = [f"# fraction of waveforms passing all waveform cuts ({args.runs} runs)"]
    lines += [f"# {c}: {display_name(names[c], d)}  ({d})" for c, d in fits.items()]
    lines += [
             f"{'HV_kV':>7} {'run':>7} " + " ".join(f"{c:>22}" for c in fits)]
    for kv, run in run_set(args.runs).items():
        cells = []
        for fit_dir in fits.values():
            eff = efficiency(fit_dir, run)
            cells.append("-" if eff is None or eff[1] == 0
                         else f"{eff[0] / eff[1]:.3f} ({eff[0]}/{eff[1]})")
        lines.append(f"{kv:>7} {run:>7} " + " ".join(f"{c:>22}" for c in cells))
    table = "\n".join(lines)
    print(table)
    (out_dir / f"efficiency_{stem}.txt").write_text(table + "\n")

    # ---- fit parameters vs field
    if args.modules:
        modules = args.modules.split(",")
    else:
        modules = sorted({p.parent.name for d in fits.values()
                          for p in (d / "plots_bertolini_avg").glob("*/parameters/")})
    if not modules:
        print("\nno fit results found; run the fit stage first")
        return 1

    for module in modules:
        tables = {c: fit_tables(d, module) for c, d in fits.items()}
        missing = [c for c, t in tables.items() if t is None]
        for c in missing:
            print(f"[missing] {module} fit of cut set {c}")
        tables = {c: t for c, t in tables.items() if t is not None}
        if not tables:
            continue

        linestyles = template_linestyles(fits[c] for c in tables)
        fig, axes = plt.subplots(2, 3, figsize=(15, 8), sharex=True)
        for ax, (table, column, label) in zip(axes.flat, PANELS):
            for i, (cutset, t) in enumerate(tables.items()):
                df = t[table]
                err = df[f"{column}_err"] if f"{column}_err" in df else None
                # small horizontal offset so overlapping points stay visible
                x = df["efield_kVcm"] * (1 + 0.006 * (i - (len(tables) - 1) / 2))
                ax.errorbar(x, df[column], yerr=err, fmt="o", ms=4, capsize=2,
                            ls=linestyles[templates(fits[cutset]) or "?"],
                            label=display_name(names[cutset], fits[cutset]))
            ax.set_ylabel(label)
            ax.grid(alpha=0.3)
        for ax in axes[-1]:
            ax.set_xlabel("Electric field [kV/cm]")
        # below the panels: the labels (cut set, templates, tag) are long
        legend_height = 0.03 * len(tables) + 0.02
        fig.legend(*axes.flat[0].get_legend_handles_labels(), loc="lower center",
                   fontsize=9, frameon=False)
        fig.suptitle(f"{module}: cut-set comparison ({args.runs} runs, "
                     f"{templates_title(fits[c] for c in tables)})")
        fig.tight_layout(rect=(0, legend_height, 1, 1))
        path = out_dir / f"compare_{module}_{stem}.png"
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"\n{module}: {path}")

        cols = ["field_kV", "tau_slow", "tau_slow_err", "chi2_ndof", "valid"]
        for cutset, t in tables.items():
            print(f"  {display_name(names[cutset], fits[cutset])}")
            print(t["params"][cols].to_string(index=False,
                                              float_format=lambda v: f"{v:.4g}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
