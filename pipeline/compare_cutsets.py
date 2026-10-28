"""Compare cut sets processed by pipeline/run_pipeline.sh.

For each module it overlays the fit parameters and the light integrals of
every cut set against the electric field, and prints the selection
efficiency (waveforms surviving all waveform cuts) per run and cut set.

Usage:
    python pipeline/compare_cutsets.py CUTSET [CUTSET ...] [--runs reduced|full]
                                       [--modules M5,M6] [--out DIR]

Reads:
    $PDS_OUTPUT/pipeline/<cutset>/<runs>/plots_bertolini_avg/<module>/parameters/
    $PDS_OUTPUT/pipeline/<cutset>/<runs>/selection/selection_cuts_*.txt
        (the cut flow copied at fit time; the selection folder itself is
        shared by cut sets with the same coincidence tag)
Writes (default $PDS_OUTPUT/pipeline/compare/<runs>/):
    compare_<module>_<cutsets>.png
    efficiency_<cutsets>.txt
"""
import argparse
import re
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


def read_table(path):
    return pd.read_csv(path, sep=r"\s+", comment="#")


def sample_tag(cutset, runs):
    """Sample tag the cut set was fitted on (sample.txt written by the
    pipeline's fit stage), or None for older fits."""
    path = paths.OUTPUT_DIR / "pipeline" / cutset / runs / "sample.txt"
    if not path.is_file():
        return None
    match = re.search(r"^sample tag : (\S+)", path.read_text(), re.M)
    return match.group(1) if match else None


def display_name(cutset, runs):
    tag = sample_tag(cutset, runs)
    return f"{cutset} [{tag}]" if tag else cutset


def fit_tables(cutset, runs, module):
    folder = (paths.OUTPUT_DIR / "pipeline" / cutset / runs
              / "plots_bertolini_avg" / module / "parameters")
    params = folder / "fit_params_vs_field.txt"
    integrals = folder / "integrals_vs_field.txt"
    if not (params.is_file() and integrals.is_file()):
        return None
    return {"params": read_table(params), "integrals": read_table(integrals)}


def efficiency(cutset, runs, run):
    """(accepted, total) summed over the saved channels, or None."""
    folder = paths.OUTPUT_DIR / "pipeline" / cutset / runs / "selection"
    files = sorted(folder.glob(f"selection_cuts_*_run_{run}_*.txt"))
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
    stem = "_vs_".join(args.cutsets)

    # ---- selection efficiency per run
    lines = [f"# fraction of waveforms passing all waveform cuts ({args.runs} runs)"]
    lines += [f"# {display_name(c, args.runs)}" for c in args.cutsets]
    lines += [
             f"{'HV_kV':>7} {'run':>7} " + " ".join(f"{c:>22}" for c in args.cutsets)]
    for kv, run in run_set(args.runs).items():
        cells = []
        for cutset in args.cutsets:
            eff = efficiency(cutset, args.runs, run)
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
        modules = sorted({p.parent.name for c in args.cutsets
                          for p in (paths.OUTPUT_DIR / "pipeline" / c / args.runs
                                    / "plots_bertolini_avg").glob("*/parameters/")})
    if not modules:
        print("\nno fit results found; run the fit stage first")
        return 1

    for module in modules:
        tables = {c: fit_tables(c, args.runs, module) for c in args.cutsets}
        missing = [c for c, t in tables.items() if t is None]
        for c in missing:
            print(f"[missing] {module} fit of cut set {c}")
        tables = {c: t for c, t in tables.items() if t is not None}
        if not tables:
            continue

        fig, axes = plt.subplots(2, 3, figsize=(15, 8), sharex=True)
        for ax, (table, column, label) in zip(axes.flat, PANELS):
            for i, (cutset, t) in enumerate(tables.items()):
                df = t[table]
                err = df[f"{column}_err"] if f"{column}_err" in df else None
                # small horizontal offset so overlapping points stay visible
                x = df["efield_kVcm"] * (1 + 0.006 * (i - (len(tables) - 1) / 2))
                ax.errorbar(x, df[column], yerr=err, fmt="o-", ms=4,
                            capsize=2, label=display_name(cutset, args.runs))
            ax.set_ylabel(label)
            ax.grid(alpha=0.3)
        for ax in axes[-1]:
            ax.set_xlabel("Electric field [kV/cm]")
        axes.flat[0].legend(fontsize=9)
        fig.suptitle(f"{module}: cut-set comparison ({args.runs} runs)")
        fig.tight_layout()
        path = out_dir / f"compare_{module}_{stem}.png"
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"\n{module}: {path}")

        cols = ["field_kV", "tau_slow", "tau_slow_err", "chi2_ndof", "valid"]
        for cutset, t in tables.items():
            print(f"  {display_name(cutset, args.runs)}")
            print(t["params"][cols].to_string(index=False,
                                              float_format=lambda v: f"{v:.4g}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
