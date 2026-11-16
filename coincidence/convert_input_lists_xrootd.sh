#!/usr/bin/env bash
#
# Rewrite the /pnfs paths in the input lists as xrootd URIs, in place.
#
#   /pnfs/dune/persistent/users/...root
#   -> root://fndcadoor.fnal.gov:1094//pnfs/fnal.gov/usr/dune/persistent/users/...root
#
# Reading through xrootd streams the file from dCache instead of going through
# the NFS mount, which is faster and also works on grid nodes without /pnfs.
#
# The URI comes from `pnfs2xrootd` (on PATH, or a copy next to this script).
# On AL9 machines that do not ship it, the script falls back to the same
# prefix substitution pnfs2xrootd performs for FNAL dCache.
#
# Lines that are blank, comments, or already root:// URIs are left untouched,
# so running the script twice is harmless. --restore converts back to /pnfs.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_TARGET="$SCRIPT_DIR/input_lists"

XROOTD_PREFIX="root://fndcadoor.fnal.gov:1094//pnfs/fnal.gov/usr/"
PNFS_PREFIX="/pnfs/"

usage() {
    cat <<EOF
Usage: $0 [options] [LIST_FILE_OR_DIR ...]

Converts every /pnfs path in the input lists to an xrootd URI, in place.
Directories are searched recursively for *.txt files.
Default target: $DEFAULT_TARGET

Options:
  -n, --dry-run     Show what would change without writing any file
  -r, --restore     Convert root:// URIs back to /pnfs paths
  -c, --check       After converting, stat every URI with xrdfs (slow)
  -b, --builtin     Skip pnfs2xrootd and use the built-in prefix substitution
  -h, --help        Show this help
EOF
}

dry_run=0
restore=0
check=0
force_builtin=0
targets=()

while (($# > 0)); do
    case $1 in
        -n|--dry-run) dry_run=1 ;;
        -r|--restore) restore=1 ;;
        -c|--check)   check=1 ;;
        -b|--builtin) force_builtin=1 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; targets+=("$@"); break ;;
        -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            targets+=("$1") ;;
    esac
    shift
done
((${#targets[@]} > 0)) || targets=("$DEFAULT_TARGET")

# ---------------------------------------------------------------------------
# Pick the converter
# ---------------------------------------------------------------------------
PNFS2XROOTD=""
if ((!restore && !force_builtin)); then
    if command -v pnfs2xrootd >/dev/null 2>&1; then
        PNFS2XROOTD=$(command -v pnfs2xrootd)
    elif [[ -x $SCRIPT_DIR/pnfs2xrootd ]]; then
        PNFS2XROOTD="$SCRIPT_DIR/pnfs2xrootd"
    else
        echo "Warning: pnfs2xrootd not found on PATH or in $SCRIPT_DIR;" >&2
        echo "         using built-in substitution /pnfs/ -> $XROOTD_PREFIX" >&2
    fi
fi
[[ -n $PNFS2XROOTD ]] && echo "Using converter: $PNFS2XROOTD"

builtin_to_xrootd() {
    printf '%s\n' "${XROOTD_PREFIX}${1#"$PNFS_PREFIX"}"
}

to_xrootd() {
    local path=$1 uri
    if [[ -n $PNFS2XROOTD ]]; then
        uri=$("$PNFS2XROOTD" "$path" 2>/dev/null | head -n 1 | tr -d '[:space:]') || true
        if [[ $uri != root://* && $uri != roots://* ]]; then
            printf '%s\n' "pnfs2xrootd returned '${uri}'"
            return 1
        fi
        printf '%s\n' "$uri"
    else
        builtin_to_xrootd "$path"
    fi
}

to_pnfs() {
    local uri=$1
    # Strip "root[s]://host[:port]/" then the "/pnfs/<site>/usr/" dCache prefix.
    local path=${uri#*://*/}
    path="/${path#/}"
    if [[ $path =~ ^/pnfs/[^/]+/usr/(.*)$ ]]; then
        path="/pnfs/${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# Collect list files
# ---------------------------------------------------------------------------
list_files=()
for target in "${targets[@]}"; do
    if [[ -d $target ]]; then
        while IFS= read -r -d '' f; do
            list_files+=("$f")
        done < <(find "$target" -type f -name '*.txt' -print0 | sort -z)
    elif [[ -f $target ]]; then
        list_files+=("$target")
    else
        echo "Error: $target is not a file or directory" >&2
        exit 1
    fi
done
if ((${#list_files[@]} == 0)); then
    echo "No input lists found in: ${targets[*]}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Convert
# ---------------------------------------------------------------------------
files_changed=0
lines_changed=0
uris_to_check=()
failures=()   # "list:line_number: path (reason)" for lines left unconverted

for list in "${list_files[@]}"; do
    tmp=$(mktemp "${list}.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    changed=0
    line_number=0

    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        # Trim surrounding whitespace for the test, but write unchanged lines verbatim.
        stripped=${line#"${line%%[![:space:]]*}"}
        stripped=${stripped%"${stripped##*[![:space:]]}"}

        new=$line
        if ((restore)); then
            if [[ $stripped == root://* || $stripped == roots://* ]]; then
                new=$(to_pnfs "$stripped")
            fi
        elif [[ $stripped == /pnfs/* ]]; then
            # On failure keep the original line and report it at the end.
            if ! new=$(to_xrootd "$stripped"); then
                failures+=("$list:$line_number: $stripped ($new)")
                echo "  Skipped $list:$line_number ($new)" >&2
                new=$line
            fi
        fi

        if [[ $new != "$line" ]]; then
            changed=$((changed + 1))
            ((dry_run)) && printf '  %s\n    -> %s\n' "$stripped" "$new"
        fi
        if ((check && !restore)) && [[ $new == root://* || $new == roots://* ]]; then
            uris_to_check+=("$new")
        fi
        printf '%s\n' "$new" >> "$tmp"
    done < "$list"

    if ((changed > 0)); then
        files_changed=$((files_changed + 1))
        lines_changed=$((lines_changed + changed))
        if ((dry_run)); then
            echo "[dry-run] $list: $changed line(s) would change"
            rm -f "$tmp"
        else
            chmod --reference="$list" "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$list"
            echo "Updated $list ($changed line(s))"
        fi
    else
        rm -f "$tmp"
    fi
    trap - EXIT
done

verb=$( ((dry_run)) && echo "would be changed" || echo "changed" )
echo "----------------------------------------"
echo "${#list_files[@]} list(s) scanned, $files_changed file(s) / $lines_changed line(s) $verb"

if ((${#failures[@]} > 0)); then
    echo "----------------------------------------"
    echo "WARNING: ${#failures[@]} line(s) could not be converted and were left as /pnfs paths:"
    printf '  %s\n' "${failures[@]}"
    echo "Check that these files still exist (ls the path) and rerun the script;"
    echo "lines that are already root:// are skipped, so only these will be retried."
fi

# ---------------------------------------------------------------------------
# Optional: verify the URIs resolve
# ---------------------------------------------------------------------------
if ((check && ${#uris_to_check[@]} > 0)); then
    if ! command -v xrdfs >/dev/null 2>&1; then
        echo "Error: --check needs xrdfs (set up the DUNE/xrootd environment first)" >&2
        exit 1
    fi
    echo "Checking ${#uris_to_check[@]} URI(s) with xrdfs ..."
    missing=0
    for uri in "${uris_to_check[@]}"; do
        rest=${uri#*://}
        server=${rest%%/*}
        path=${rest#*/}   # "host:1094//pnfs/..." -> "/pnfs/..."
        if ! xrdfs "$server" stat "$path" >/dev/null 2>&1; then
            echo "  MISSING: $uri" >&2
            missing=$((missing + 1))
        fi
    done
    if ((missing > 0)); then
        echo "$missing URI(s) could not be stat'ed" >&2
        exit 1
    fi
    echo "All URIs reachable."
fi
