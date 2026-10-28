"""X-ARAPUCA modules: channel numbers and detector-response templates.

Channel convention (LArSoft map, as in coincidence_lib.py and calibration/):
membrane module Mk -> channels 20k0 (array 1) and 20k1 (array 2), cathode
module Ck -> 10k0 and 10k1. So M8 -> 2080/2081, C1 -> 1010/1011.

Template sets (one file per module and SiPM array, template_RUN_MODULE_ARRAY.txt):

    large_pulse  reference/large_pulse_templates/  (default) LED large pulses,
                 every module except M2 array 1
    francesca    reference/spe_templates/francesca/  M5, M6, M7, M8

A module's channels are those arrays that have a template in the set, so M2
fits channel 2021 alone with large_pulse.

    python3 -m pds.modules [--templates SET]   # prints "MODULE ch [ch]" lines

No numpy import: the pipeline driver calls this with any python3.
"""
import argparse
import re
from pathlib import Path

REFERENCE_DIR = Path(__file__).resolve().parents[1] / "reference"
TEMPLATE_SETS = {
    "large_pulse": REFERENCE_DIR / "large_pulse_templates",
    "francesca": REFERENCE_DIR / "spe_templates" / "francesca",
}
DEFAULT_TEMPLATES = "large_pulse"
MODULE_NAMES = tuple(f"M{i}" for i in range(1, 9)) + tuple(f"C{i}" for i in range(1, 9))

_TEMPLATE_RE = re.compile(r"^template_(\d+)_([MC][1-8])_([12])\.txt$")


def channel(module, array):
    """Channel number of a module's SiPM array (1 or 2)."""
    base = 2000 if module[0] == "M" else 1000
    return base + 10 * int(module[1:]) + (array - 1)


def templates(templates_set=DEFAULT_TEMPLATES):
    """{module: [(channel, template path), ...]} for every module with at
    least one template in the set, arrays in order."""
    if templates_set not in TEMPLATE_SETS:
        raise ValueError(f"unknown template set {templates_set!r}; "
                         f"known: {', '.join(TEMPLATE_SETS)}")
    found = {}
    for path in sorted(TEMPLATE_SETS[templates_set].glob("template_*.txt")):
        match = _TEMPLATE_RE.match(path.name)
        if not match:
            continue
        module, array = match.group(2), int(match.group(3))
        arrays = found.setdefault(module, {})
        if array in arrays:
            raise ValueError(f"two templates for {module} array {array} in "
                             f"{TEMPLATE_SETS[templates_set]}: "
                             f"{arrays[array].name}, {path.name}")
        arrays[array] = path
    return {module: [(channel(module, a), found[module][a]) for a in sorted(found[module])]
            for module in MODULE_NAMES if module in found}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--templates", default=DEFAULT_TEMPLATES, choices=tuple(TEMPLATE_SETS))
    args = parser.parse_args()
    for module, entries in templates(args.templates).items():
        print(module, *(ch for ch, _ in entries))


if __name__ == "__main__":
    main()
