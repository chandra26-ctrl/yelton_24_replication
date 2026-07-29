"""Plot the number of quasiparticles created as a function of creation time."""

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


CREATION_TIME_COLUMN = "Creation Time [ns]"
PATCH_COLUMN = "Patch"

# User setting: file containing the quasiparticle data to read and analyze.
INPUT_FILE = "combined_qp_results_Cu.txt"

# User setting: aluminum patch to include in the histogram.
AL_PATCH = "AlPatch_1_1"

# User setting: width of each histogram time bin, in nanoseconds.
TIME_BIN_WIDTH_NS = 50

# User setting: time unit shown on the plot. Use "ns" or "us".
PLOT_TIME_UNIT = "us"

# User settings for optionally ignoring unusually late creation times.
# For example, 99.9 keeps the earliest 99.9% of the data.
IGNORE_OUTLIERS = True
OUTLIER_PERCENTILE = 100 # 99.9


def load_creation_times(file_path, al_patch=AL_PATCH):
    """Load QP creation times in nanoseconds for one aluminum patch."""
    creation_times = []

    with open(file_path, "r", newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file)
        required_columns = {CREATION_TIME_COLUMN, PATCH_COLUMN}
        missing_columns = required_columns.difference(reader.fieldnames or [])
        if missing_columns:
            available = ", ".join(reader.fieldnames or []) or "none"
            raise ValueError(
                f"Missing column(s) {', '.join(sorted(missing_columns))}. "
                f"Available columns: {available}"
            )

        for line_number, row in enumerate(reader, start=2):
            if (row.get(PATCH_COLUMN) or "").strip() != al_patch:
                continue
            value = (row.get(CREATION_TIME_COLUMN) or "").strip()
            if not value:
                continue
            try:
                creation_times.append(float(value))
            except ValueError as error:
                raise ValueError(
                    f"Invalid creation time {value!r} on line {line_number}"
                ) from error

    if not creation_times:
        raise ValueError(
            f"No QP creation times were found for aluminum patch {al_patch!r}."
        )

    return np.asarray(creation_times)


def bin_edges_for_width(values, bin_width):
    """Build edges that cover all values using the requested width in nanoseconds."""
    if bin_width <= 0:
        raise ValueError("Bin width must be greater than zero.")

    start = np.floor(values.min() / bin_width) * bin_width
    stop = np.ceil(values.max() / bin_width) * bin_width
    if stop <= start:
        stop = start + bin_width

    return np.arange(start, stop + bin_width * 0.5, bin_width)


def remove_outliers(values, percentile):
    """Discard creation times above the requested percentile."""
    if not 0 < percentile <= 100:
        raise ValueError("Outlier percentile must be greater than 0 and at most 100.")

    cutoff = np.percentile(values, percentile)
    filtered_values = values[values <= cutoff]
    ignored_count = len(values) - len(filtered_values)
    return filtered_values, ignored_count, cutoff


def convert_time_from_ns(values, time_unit):
    """Convert nanoseconds to the selected plot unit."""
    if time_unit == "ns":
        return values, "ns"
    if time_unit == "us":
        return values / 1000.0, "\N{GREEK SMALL LETTER MU}s"
    raise ValueError('PLOT_TIME_UNIT must be either "ns" or "us".')


def plot_histogram(
    creation_times,
    bins,
    output_path=None,
    al_patch=AL_PATCH,
    time_unit=PLOT_TIME_UNIT,
):
    """Create the QP creation-time histogram and optionally save it."""
    plotted_times, unit_label = convert_time_from_ns(creation_times, time_unit)
    plotted_bins = bins
    if not np.isscalar(bins):
        plotted_bins, _ = convert_time_from_ns(np.asarray(bins), time_unit)

    figure, axis = plt.subplots(figsize=(10, 6))
    counts, _, _ = axis.hist(
        plotted_times,
        bins=plotted_bins,
        edgecolor="black",
        linewidth=0.8,
        color="tab:blue",
    )
    axis.set_xlabel(f"Creation time [{unit_label}]")
    axis.set_ylabel("Number of QPs created")
    axis.set_title(f"Quasiparticle creation-time histogram: {al_patch}")
    axis.grid(axis="y", alpha=0.25)
    axis.yaxis.get_major_locator().set_params(integer=True)
    figure.tight_layout()

    if output_path:
        figure.savefig(output_path, dpi=300)
        print(f"Saved histogram to {output_path}")
    else:
        plt.show()

    return counts


def parse_args():
    parser = argparse.ArgumentParser(
        description="Plot how many quasiparticles were created in each time interval."
    )
    parser.add_argument(
        "file",
        nargs="?",
        default=INPUT_FILE,
        help=f"input CSV file (default: INPUT_FILE = {INPUT_FILE})",
    )
    bin_group = parser.add_mutually_exclusive_group()
    bin_group.add_argument(
        "--bins",
        type=int,
        help="number of equal-width time bins (overrides TIME_BIN_WIDTH_NS)",
    )
    bin_group.add_argument(
        "--bin-width",
        type=float,
        metavar="NS",
        help=(
            "width of each time bin in nanoseconds "
            f"(default: TIME_BIN_WIDTH_NS = {TIME_BIN_WIDTH_NS})"
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="save the plot (for example, qp_creation_histogram.png) instead of showing it",
    )
    args = parser.parse_args()

    if args.bins is not None and args.bins <= 0:
        parser.error("--bins must be greater than zero")
    if args.bin_width is not None and args.bin_width <= 0:
        parser.error("--bin-width must be greater than zero")

    return args


def main():
    args = parse_args()
    creation_times = load_creation_times(args.file, AL_PATCH)
    original_count = len(creation_times)

    if IGNORE_OUTLIERS:
        creation_times, ignored_count, cutoff = remove_outliers(
            creation_times, OUTLIER_PERCENTILE
        )
        print(
            f"Ignored {ignored_count} outliers above the "
            f"{OUTLIER_PERCENTILE:g}th percentile ({cutoff:g} ns)."
        )

    if args.bins is not None:
        bins = args.bins
    else:
        bin_width = (
            args.bin_width if args.bin_width is not None else TIME_BIN_WIDTH_NS
        )
        bins = bin_edges_for_width(creation_times, bin_width)

    counts = plot_histogram(
        creation_times,
        bins,
        output_path=args.output,
        al_patch=AL_PATCH,
        time_unit=PLOT_TIME_UNIT,
    )
    print(
        f"Read {original_count} QPs from {AL_PATCH}; "
        f"plotted {len(creation_times)}; "
        f"maximum bin count: {int(counts.max())}"
    )


if __name__ == "__main__":
    main()
