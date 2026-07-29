"""Plot the non-Cu quasiparticle response from Yelton et al., Fig. 3(b).

The model is Eq. (1) of Yelton et al., Phys. Rev. B 110, 024519 (2024):

    dx_qp/dt = -r*x_qp**2 - s*x_qp + g(t)

All times in this script are in microseconds, so ``g(t)`` and the rates have
units of inverse microseconds.

The quasiparticle creation times in ``combined_qp_results.txt`` and
``combined_qp_results_Cu.txt`` are each converted into the response per
simulated phonon:

    h(t_i) = N_qp(t_i) / (n_cp * V * delta_t * N_ph_simulated)

The physical generation rate is then calculated by convolving h(t) with the
experimental square-pulse phonon injection rate:

    g(t) = integral h(t - tau) * I_ph(tau) d_tau

where I_ph = 1.673 * V_bias / (2 * e * R_n) during the pulse and zero
otherwise. Times in the input file are converted from nanoseconds to
microseconds.
"""

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


# Parameters reported for Fig. 3(b).
RECOMBINATION_RATE_PER_US = 100.0  # r = 1/(10 ns)
NON_CU_TRAPPING_RATE_PER_US = 4.5e-2  # non-Cu-A, Q4
CU_TRAPPING_RATE_PER_US = 5.0e-2      # 10-um Cu device

# User settings.
DATA_FILE = "combined_qp_results.txt"
CU_DATA_FILE = "combined_qp_results_Cu.txt"
NON_CU_AL_PATCH = "AlPatch_1_0"  # Q4
CU_AL_PATCH = "AlPatch_1_1"      # Q3
TIME_BIN_WIDTH_US = 1.0

# Phonon simulation and experimental injection settings for Fig. 3(b).
NON_CU_SIMULATED_PHONON_COUNT = 1.0e8
CU_SIMULATED_PHONON_COUNT = 1.0e9
INJECTION_PULSE_DURATION_US = 10.0
INJECTOR_BIAS_V = 1.0e-3
INJECTOR_RESISTANCE_OHM = 2.6e3
PAIR_BREAKING_PHONONS_PER_PAIR = 1.673

# Electrode values used by Yelton et al. to convert N_qp(t) to g(t).
COOPER_PAIR_DENSITY_PER_UM3 = 4.0e6
ELECTRODE_VOLUME_UM3 = 10 * 10 * 0.12 # 1.0 * 5.0 * 0.12
ELEMENTARY_CHARGE_C = 1.602176634e-19

CREATION_TIME_COLUMN = "Creation Time [ns]"
PATCH_COLUMN = "Patch"


def load_creation_times(file_path, al_patch):
    """Load QP creation times, in microseconds, for one aluminum patch."""
    creation_times_ns = []
    with open(file_path, "r", newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file)
        required = {CREATION_TIME_COLUMN, PATCH_COLUMN}
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ValueError(
                "QP data file is missing column(s): " + ", ".join(sorted(missing))
            )

        for line_number, row in enumerate(reader, start=2):
            if (row.get(PATCH_COLUMN) or "").strip() != al_patch:
                continue
            value = (row.get(CREATION_TIME_COLUMN) or "").strip()
            if not value:
                continue
            try:
                creation_times_ns.append(float(value))
            except ValueError as error:
                raise ValueError(
                    f"Invalid creation time {value!r} on line {line_number}."
                ) from error

    if not creation_times_ns:
        raise ValueError(
            f"No QP creation times were found for aluminum patch {al_patch!r}."
        )

    return np.asarray(creation_times_ns) / 1000.0


def generation_rate_from_data(
    file_path,
    al_patch=NON_CU_AL_PATCH,
    bin_width_us=TIME_BIN_WIDTH_US,
    simulated_phonon_count=NON_CU_SIMULATED_PHONON_COUNT,
    pulse_duration_us=INJECTION_PULSE_DURATION_US,
    injector_bias_v=INJECTOR_BIAS_V,
    injector_resistance_ohm=INJECTOR_RESISTANCE_OHM,
    phonons_per_pair=PAIR_BREAKING_PHONONS_PER_PAIR,
    cooper_pair_density=COOPER_PAIR_DENSITY_PER_UM3,
    electrode_volume=ELECTRODE_VOLUME_UM3,
):
    """Normalize N_qp into h(t), then convolve h(t) with the injection pulse."""
    if bin_width_us <= 0:
        raise ValueError("g(t) bin width must be positive.")
    if simulated_phonon_count <= 0:
        raise ValueError("simulated phonon count must be positive.")
    if pulse_duration_us <= 0:
        raise ValueError("injection pulse duration must be positive.")
    if injector_bias_v <= 0 or injector_resistance_ohm <= 0:
        raise ValueError("injector bias and resistance must be positive.")
    if phonons_per_pair <= 0:
        raise ValueError("phonons per broken pair must be positive.")
    if cooper_pair_density <= 0 or electrode_volume <= 0:
        raise ValueError("Cooper-pair density and electrode volume must be positive.")

    creation_times_us = load_creation_times(file_path, al_patch)
    stop_us = np.ceil(creation_times_us.max() / bin_width_us) * bin_width_us
    if stop_us <= 0:
        stop_us = bin_width_us
    bin_edges_us = np.arange(0.0, stop_us + bin_width_us * 0.5, bin_width_us)
    counts, _ = np.histogram(creation_times_us, bins=bin_edges_us)

    # Equation (2): response per simulated phonon, in us^-1 phonon^-1.
    response_per_us_per_phonon = counts / (
        cooper_pair_density
        * electrode_volume
        * bin_width_us
        * simulated_phonon_count
    )

    # Equation (4): square-pulse injection rate, converted from s^-1 to us^-1.
    broken_pairs_per_us = (
        injector_bias_v
        / (2.0 * ELEMENTARY_CHARGE_C * injector_resistance_ohm)
        * 1.0e-6
    )
    injected_phonons_per_us = phonons_per_pair * broken_pairs_per_us
    pulse_bin_count = int(np.ceil(pulse_duration_us / bin_width_us))
    injection_rate = np.full(pulse_bin_count, injected_phonons_per_us)
    final_bin_fraction = (
        pulse_duration_us - (pulse_bin_count - 1) * bin_width_us
    ) / bin_width_us
    injection_rate[-1] *= final_bin_fraction

    # Equation (3): discrete convolution. The factor delta_t approximates the
    # time integral and gives g(t) in us^-1.
    generation_rate_per_us = (
        np.convolve(response_per_us_per_phonon, injection_rate)
        * bin_width_us
    )
    generation_edges_us = np.arange(
        len(generation_rate_per_us) + 1, dtype=float
    ) * bin_width_us

    def g_from_histogram(t_us):
        values = np.asarray(t_us, dtype=float)
        indices = np.searchsorted(generation_edges_us, values, side="right") - 1
        valid = (indices >= 0) & (indices < len(generation_rate_per_us))
        safe_indices = np.clip(indices, 0, len(generation_rate_per_us) - 1)
        return np.where(valid, generation_rate_per_us[safe_indices], 0.0)

    details = {
        "creation_times_us": creation_times_us,
        "counts": counts,
        "response_per_us_per_phonon": response_per_us_per_phonon,
        "injected_phonons_per_us": injected_phonons_per_us,
        "generation_rate_per_us": generation_rate_per_us,
    }
    return g_from_histogram, generation_edges_us, details


def evaluate_g(g_function, t_us):
    """Evaluate and validate g(t), accepting scalar-only user functions too."""
    try:
        value = g_function(t_us)
    except (TypeError, ValueError):
        value = np.asarray([g_function(float(t)) for t in np.atleast_1d(t_us)])

    value = np.asarray(value, dtype=float)
    if value.size == 1:
        value = np.full(np.shape(t_us), value.item(), dtype=float)
    else:
        value = np.broadcast_to(value, np.shape(t_us)).astype(float, copy=False)

    if not np.all(np.isfinite(value)):
        raise ValueError("g(t) returned a NaN or infinite value.")
    if np.any(value < 0):
        raise ValueError("g(t) must be nonnegative.")
    return value


def solve_xqp(
    g_function,
    start_us,
    stop_us,
    dt_us,
    xqp_initial=0.0,
    recombination_rate=RECOMBINATION_RATE_PER_US,
    trapping_rate=NON_CU_TRAPPING_RATE_PER_US,
):
    """Solve the QP rate equation with the paper's forward-Euler method."""
    if stop_us <= start_us:
        raise ValueError("stop time must be greater than start time.")
    if dt_us <= 0:
        raise ValueError("time step must be positive.")
    if xqp_initial < 0:
        raise ValueError("initial x_qp must be nonnegative.")
    if recombination_rate < 0 or trapping_rate < 0:
        raise ValueError("r and s must be nonnegative.")

    count = int(np.ceil((stop_us - start_us) / dt_us)) + 1
    time_us = np.linspace(start_us, stop_us, count)
    actual_dt = time_us[1] - time_us[0]
    generation_rate = evaluate_g(g_function, time_us)

    xqp = np.empty_like(time_us)
    xqp[0] = xqp_initial
    for index in range(len(time_us) - 1):
        loss = recombination_rate * xqp[index] ** 2 + trapping_rate * xqp[index]
        xqp[index + 1] = xqp[index] + actual_dt * (
            generation_rate[index] - loss
        )
        if xqp[index + 1] < 0:
            xqp[index + 1] = 0.0

    return time_us, xqp


def plot_comparison(
    time_us,
    xqp,
    cu_time_us,
    cu_xqp,
    non_cu_patch,
    cu_patch,
    output_path=None,
):
    """Plot the modeled responses from the non-Cu and Cu result files."""
    figure, axis = plt.subplots(figsize=(7.2, 4.8))
    axis.plot(
        time_us,
        xqp,
        color="#c62828",
        linewidth=2.2,
        label="non-Cu-A model",
    )
    axis.plot(
        cu_time_us,
        cu_xqp,
        color="#1565c0",
        linewidth=2.2,
        label="Cu model",
    )
    axis.set_xlabel(r"Time ($\mu$s)")
    axis.set_ylabel(r"$x_{\mathrm{qp}}$")
    axis.set_title(
        f"QP response to phonon injection: "
        f"non-Cu {non_cu_patch}, Cu {cu_patch}"
    )
    axis.ticklabel_format(axis="y", style="sci", scilimits=(0, 0))
    axis.set_xlim(
        min(time_us[0], cu_time_us[0]),
        max(time_us[-1], cu_time_us[-1]),
    )
    axis.set_ylim(bottom=0.0)
    axis.grid(alpha=0.2)
    axis.legend(frameon=False)
    figure.tight_layout()

    if output_path is not None:
        figure.savefig(output_path, dpi=300)
        print(f"Saved plot to {output_path}")
    else:
        plt.show()

    return figure


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Solve the Yelton et al. QP rate equation using non-Cu and Cu "
            "combined QP creation data and compare their responses."
        )
    )
    parser.add_argument(
        "--data-file",
        type=Path,
        default=Path(DATA_FILE),
        help=f"non-Cu combined QP data file (default: {DATA_FILE})",
    )
    parser.add_argument(
        "--cu-data-file",
        type=Path,
        default=Path(CU_DATA_FILE),
        help=f"Cu combined QP data file (default: {CU_DATA_FILE})",
    )
    parser.add_argument(
        "--non-cu-patch",
        default=NON_CU_AL_PATCH,
        help=f"non-Cu Q4 patch (default: {NON_CU_AL_PATCH})",
    )
    parser.add_argument(
        "--cu-patch",
        default=CU_AL_PATCH,
        help=f"10-um Cu Q3 patch (default: {CU_AL_PATCH})",
    )
    parser.add_argument(
        "--bin-width",
        type=float,
        default=TIME_BIN_WIDTH_US,
        help=f"width of the N_qp(t) bins [us] (default: {TIME_BIN_WIDTH_US})",
    )
    parser.add_argument(
        "--non-cu-simulated-phonons",
        type=float,
        default=NON_CU_SIMULATED_PHONON_COUNT,
        help=(
            "number of phonons represented by the non-Cu data "
            f"(default: {NON_CU_SIMULATED_PHONON_COUNT:g})"
        ),
    )
    parser.add_argument(
        "--cu-simulated-phonons",
        type=float,
        default=CU_SIMULATED_PHONON_COUNT,
        help=(
            "number of phonons represented by the Cu data "
            f"(default: {CU_SIMULATED_PHONON_COUNT:g})"
        ),
    )
    parser.add_argument(
        "--pulse-duration",
        type=float,
        default=INJECTION_PULSE_DURATION_US,
        help=f"injection pulse duration [us] (default: {INJECTION_PULSE_DURATION_US:g})",
    )
    parser.add_argument(
        "--bias",
        type=float,
        default=INJECTOR_BIAS_V,
        help=f"injector bias [V] (default: {INJECTOR_BIAS_V:g})",
    )
    parser.add_argument(
        "--injector-resistance",
        type=float,
        default=INJECTOR_RESISTANCE_OHM,
        help=(
            "injector normal-state resistance [ohm] "
            f"(default: {INJECTOR_RESISTANCE_OHM:g})"
        ),
    )
    parser.add_argument("--start", type=float, default=0.0, help="start time [us]")
    parser.add_argument(
        "--stop",
        type=float,
        help="stop time [us] (default: end of the creation-time histogram)",
    )
    parser.add_argument(
        "--dt", type=float, default=0.01, help="Euler integration step [us]"
    )
    parser.add_argument(
        "--x0", type=float, default=0.0, help="initial normalized QP density"
    )
    parser.add_argument(
        "--r",
        type=float,
        default=RECOMBINATION_RATE_PER_US,
        help="QP recombination rate [us^-1] (default: 100)",
    )
    parser.add_argument(
        "--non-cu-s",
        type=float,
        default=NON_CU_TRAPPING_RATE_PER_US,
        help="non-Cu QP trapping rate [us^-1] (default: 0.045 for Q4)",
    )
    parser.add_argument(
        "--cu-s",
        type=float,
        default=CU_TRAPPING_RATE_PER_US,
        help="10-um Cu QP trapping rate [us^-1] (default: 0.050)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="save the figure instead of opening a plot window",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    g_function, generation_edges_us, details = generation_rate_from_data(
        args.data_file,
        al_patch=args.non_cu_patch,
        bin_width_us=args.bin_width,
        simulated_phonon_count=args.non_cu_simulated_phonons,
        pulse_duration_us=args.pulse_duration,
        injector_bias_v=args.bias,
        injector_resistance_ohm=args.injector_resistance,
    )
    cu_g_function, cu_generation_edges_us, cu_details = generation_rate_from_data(
        args.cu_data_file,
        al_patch=args.cu_patch,
        bin_width_us=args.bin_width,
        simulated_phonon_count=args.cu_simulated_phonons,
        pulse_duration_us=args.pulse_duration,
        injector_bias_v=args.bias,
        injector_resistance_ohm=args.injector_resistance,
    )
    stop_us = (
        args.stop
        if args.stop is not None
        else max(generation_edges_us[-1], cu_generation_edges_us[-1])
    )
    time_us, xqp = solve_xqp(
        g_function,
        args.start,
        stop_us,
        args.dt,
        xqp_initial=args.x0,
        recombination_rate=args.r,
        trapping_rate=args.non_cu_s,
    )
    cu_time_us, cu_xqp = solve_xqp(
        cu_g_function,
        args.start,
        stop_us,
        args.dt,
        xqp_initial=args.x0,
        recombination_rate=args.r,
        trapping_rate=args.cu_s,
    )

    # Figure 3(b) defines delay zero as the end of the injection pulse.
    delay_us = time_us - args.pulse_duration
    cu_delay_us = cu_time_us - args.pulse_duration
    plot_comparison(
        delay_us,
        xqp,
        cu_delay_us,
        cu_xqp,
        args.non_cu_patch,
        args.cu_patch,
        args.output,
    )

    for (
        label,
        file_path,
        patch,
        simulated_phonons,
        result_details,
        result_delay,
        result_xqp,
    ) in (
        (
            "non-Cu",
            args.data_file,
            args.non_cu_patch,
            args.non_cu_simulated_phonons,
            details,
            delay_us,
            xqp,
        ),
        (
            "Cu",
            args.cu_data_file,
            args.cu_patch,
            args.cu_simulated_phonons,
            cu_details,
            cu_delay_us,
            cu_xqp,
        ),
    ):
        peak_index = int(np.argmax(result_xqp))
        print(
            f"{label} ({file_path}): read "
            f"{len(result_details['creation_times_us'])} QPs from {patch}; "
            f"h(t) uses {len(result_details['counts'])} bins of width "
            f"{args.bin_width:g} us."
        )
        print(
            f"Normalized h(t) by {simulated_phonons:g} simulated phonons; "
            f"square-pulse I_ph = "
            f"{result_details['injected_phonons_per_us']:.6g} us^-1 "
            f"for {args.pulse_duration:g} us."
        )
        print(
            f"Peak x_qp = {result_xqp[peak_index]:.6g} "
            f"at delay {result_delay[peak_index]:.3f} us"
        )


if __name__ == "__main__":
    main()
