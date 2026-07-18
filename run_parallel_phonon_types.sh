#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE="$ROOT/QP-build/g4cmpQuasiparticle"
BASE_MACRO="$ROOT/G4Macros/quasiparticle_resonator_targeted.mac"
CMAKE_CACHE="$ROOT/QP-build/CMakeCache.txt"

usage() {
  cat <<'EOF'
Usage:
  ./run_parallel_phonon_types.sh [jobs_per_type] [phonons_per_type] [max_retries] [types]

Arguments:
  jobs_per_type     Parallel workers used for each phonon type (default: 16)
  phonons_per_type  Total injected phonons for each selected type (default: 500000)
  max_retries       Retries for each failed worker (default: 1)
  types             Comma-separated list chosen from phononTS,phononTF,phononL
                    (default: phononTS,phononTF,phononL)

Examples:
  ./run_parallel_phonon_types.sh
  ./run_parallel_phonon_types.sh 24 5000000
  ./run_parallel_phonon_types.sh 12 1000000 2 phononTS,phononL

The selected phonon types run sequentially, while jobs within each type run in
parallel. Thus, jobs_per_type is also the maximum number of simulator processes
started at once.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

NJOBS="${1:-16}"
PHONONS_PER_TYPE="${2:-500000}"
MAX_RETRIES="${3:-1}"
TYPE_LIST="${4:-phononTS,phononTF,phononL}"

if (( $# > 4 )); then
  echo "Error: too many arguments." >&2
  usage >&2
  exit 2
fi

if [[ ! "$NJOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: jobs_per_type must be a positive integer." >&2
  exit 2
fi

if [[ ! "$PHONONS_PER_TYPE" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: phonons_per_type must be a positive integer." >&2
  exit 2
fi

if [[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "Error: max_retries must be a non-negative integer." >&2
  exit 2
fi

if (( PHONONS_PER_TYPE < NJOBS )); then
  echo "Error: phonons_per_type must be at least jobs_per_type." >&2
  exit 2
fi

IFS=',' read -r -a PHONON_TYPES <<< "$TYPE_LIST"
if (( ${#PHONON_TYPES[@]} == 0 )); then
  echo "Error: at least one phonon type is required." >&2
  exit 2
fi

declare -A SEEN_TYPES=()
for PHONON_TYPE in "${PHONON_TYPES[@]}"; do
  case "$PHONON_TYPE" in
    phononTS|phononTF|phononL) ;;
    *)
      echo "Error: invalid phonon type '$PHONON_TYPE'." >&2
      echo "Allowed types: phononTS, phononTF, phononL" >&2
      exit 2
      ;;
  esac

  if [[ -n "${SEEN_TYPES[$PHONON_TYPE]:-}" ]]; then
    echo "Error: duplicate phonon type '$PHONON_TYPE'." >&2
    exit 2
  fi
  SEEN_TYPES[$PHONON_TYPE]=1
done

if [[ ! -x "$EXE" ]]; then
  echo "Error: executable not found at $EXE" >&2
  echo "Build it first with: cmake --build QP-build -j" >&2
  exit 2
fi

if [[ ! -f "$BASE_MACRO" ]]; then
  echo "Error: macro not found at $BASE_MACRO" >&2
  exit 2
fi

# Each worker changes to its output directory, so resolve the lattice-data path
# before launching any workers.
if [[ -n "${G4LATTICEDATA:-}" ]]; then
  if [[ "$G4LATTICEDATA" = /* ]]; then
    LATTICE_DATA="$G4LATTICEDATA"
  else
    LATTICE_DATA="$ROOT/${G4LATTICEDATA#./}"
  fi
elif [[ -f "$CMAKE_CACHE" ]]; then
  G4CMP_LIBRARY="$(sed -n 's|^G4CMP_LIBRARY:FILEPATH=||p' "$CMAKE_CACHE" | head -n 1)"
  G4CMP_PREFIX="$(dirname "$(dirname "$G4CMP_LIBRARY")")"
  LATTICE_DATA="$G4CMP_PREFIX/share/G4CMP/CrystalMaps"
else
  LATTICE_DATA=""
fi

if [[ ! -f "$LATTICE_DATA/Si/config.txt" ]]; then
  echo "Error: cannot locate the G4CMP Si lattice data." >&2
  echo "Set G4LATTICEDATA to the absolute CrystalMaps directory and retry." >&2
  exit 2
fi

RUN_TAG="$(date +%Y%m%d_%H%M%S)_$$"
RUN_DIR="$ROOT/parallel_runs/phonon_types_$RUN_TAG"
mkdir -p "$RUN_DIR"

BASE_COUNT=$((PHONONS_PER_TYPE / NJOBS))
REMAINDER=$((PHONONS_PER_TYPE % NJOBS))
TOTAL_INJECTED=$((PHONONS_PER_TYPE * ${#PHONON_TYPES[@]}))

echo "Running phonon types: ${PHONON_TYPES[*]}"
echo "Phonons per type: $PHONONS_PER_TYPE"
echo "Jobs per type: $NJOBS"
echo "Total phonons across all types: $TOTAL_INJECTED"
echo "Failed jobs will be retried up to $MAX_RETRIES time(s)"
echo "Results directory: $RUN_DIR"
echo "Lattice data: $LATTICE_DATA"

make_worker_macro() {
  local output_file="$1"
  local phonon_type="$2"
  local count="$3"
  local seed1="$4"
  local seed2="$5"

  # Replace the active particle, seed, and final /gps/number command. Keeping
  # the earlier '/gps/number 1' line unchanged is harmless because the final
  # command is the value used by /run/beamOn.
  awk \
    -v phonon_type="$phonon_type" \
    -v count="$count" \
    -v seed1="$seed1" \
    -v seed2="$seed2" '
      { lines[NR] = $0 }
      /^\/gps\/number[[:space:]]+[0-9]+([[:space:]]|$)/ { final_number_line = NR }
      END {
        if (!final_number_line) exit 20
        for (i = 1; i <= NR; ++i) {
          if (lines[i] ~ /^\/gps\/particle[[:space:]]+/) {
            lines[i] = "/gps/particle " phonon_type
          } else if (lines[i] ~ /^\/random\/setSeeds[[:space:]]+/) {
            lines[i] = "/random/setSeeds " seed1 " " seed2
          } else if (i == final_number_line) {
            lines[i] = "/gps/number " count
          }
          print lines[i]
        }
      }
    ' "$BASE_MACRO" > "$output_file"
}

run_phonon_type() {
  local type_index="$1"
  local phonon_type="$2"
  local type_dir="$RUN_DIR/$phonon_type"
  local pids=()
  local i count job_dir attempt attempt_dir seed1 seed2 attempt_status
  local failed=0

  mkdir -p "$type_dir"
  echo "Starting $phonon_type"

  for ((i = 0; i < NJOBS; i++)); do
    job_dir="$type_dir/job_$i"
    mkdir -p "$job_dir"

    count=$BASE_COUNT
    if (( i < REMAINDER )); then
      count=$((count + 1))
    fi

    (
      for ((attempt = 0; attempt <= MAX_RETRIES; attempt++)); do
        attempt_dir="$job_dir/attempt_$attempt"
        mkdir -p "$attempt_dir"

        # Type, job, and retry offsets ensure independent reproducible streams.
        seed1=$((123456 + type_index * 1000000 + i + attempt * NJOBS))
        seed2=$((567890 + type_index * 2000000 + 17 * i + 104729 * attempt))

        if ! make_worker_macro "$attempt_dir/run.mac" "$phonon_type" \
          "$count" "$seed1" "$seed2"; then
          echo "Error: failed to generate $attempt_dir/run.mac" >&2
          exit 2
        fi

        ln -sfn "attempt_$attempt/run.mac" "$job_dir/run.mac"
        ln -sfn "attempt_$attempt/run.log" "$job_dir/run.log"

        echo "  $phonon_type job_$i attempt_$attempt: $count phonons, seeds $seed1 $seed2"
        attempt_status=0
        (
          cd "$attempt_dir" || exit 1
          export G4LATTICEDATA="$LATTICE_DATA"
          "$EXE" run.mac > run.log 2>&1
        ) || attempt_status=$?

        if (( attempt_status == 0 )); then
          echo "$attempt" > "$job_dir/successful_attempt.txt"
          for output_name in QuasiparticleStepInformationFile.txt phonon_hits.txt; do
            if [[ -e "$attempt_dir/$output_name" ]]; then
              ln -sfn "attempt_$attempt/$output_name" "$job_dir/$output_name"
            fi
          done
          exit 0
        fi

        echo "Warning: $phonon_type job_$i attempt_$attempt failed with status $attempt_status" >&2
        if (( attempt < MAX_RETRIES )); then
          echo "  Retrying $phonon_type job_$i with new seeds..." >&2
        fi
      done

      exit "$attempt_status"
    ) &
    pids+=("$!")
  done

  for ((i = 0; i < NJOBS; i++)); do
    if ! wait "${pids[$i]}"; then
      echo "Error: $phonon_type job_$i failed; see $type_dir/job_$i/run.log" >&2
      failed=1
    fi
  done

  if (( failed != 0 )); then
    return 1
  fi

  echo "Completed $phonon_type"
}

for TYPE_INDEX in "${!PHONON_TYPES[@]}"; do
  if ! run_phonon_type "$TYPE_INDEX" "${PHONON_TYPES[$TYPE_INDEX]}"; then
    echo "One or more jobs failed. Outputs were not merged." >&2
    exit 1
  fi
done

merge_csv_outputs() {
  local output_name="$1"
  shift

  awk '
    FNR == 1 {
      if (!printed_header) {
        print "Phonon Type,Job," $0
        printed_header = 1
      }
      next
    }
    {
      count = split(FILENAME, path, "/")
      job = path[count - 1]
      type = path[count - 2]
      sub(/^job_/, "", job)
      print type "," job "," $0
    }
  ' "$@" > "$RUN_DIR/$output_name"
}

shopt -s nullglob
QP_FILES=("$RUN_DIR"/phonon*/job_*/QuasiparticleStepInformationFile.txt)
HIT_FILES=("$RUN_DIR"/phonon*/job_*/phonon_hits.txt)
MERGED_OUTPUTS=()

if (( ${#QP_FILES[@]} > 0 )); then
  merge_csv_outputs combined_qp_results.csv "${QP_FILES[@]}"
  MERGED_OUTPUTS+=("$RUN_DIR/combined_qp_results.csv")
fi

if (( ${#HIT_FILES[@]} > 0 )); then
  merge_csv_outputs combined_phonon_hits.csv "${HIT_FILES[@]}"
  MERGED_OUTPUTS+=("$RUN_DIR/combined_phonon_hits.csv")
fi

echo "All phonon-type runs completed successfully."
if (( ${#MERGED_OUTPUTS[@]} > 0 )); then
  echo "Combined results:"
  printf '  %s\n' "${MERGED_OUTPUTS[@]}"
else
  echo "No simulator output files were produced to merge."
fi
