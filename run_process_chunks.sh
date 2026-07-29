#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${QP_BUILD_DIR:-$ROOT/QP-build}"
EXE="$BUILD_DIR/g4cmpQuasiparticle"
CMAKE_CACHE="$BUILD_DIR/CMakeCache.txt"
BASE_MACRO="$ROOT/G4Macros/quasiparticle_resonator_targeted.mac"

usage() {
  cat <<'EOF'
Usage:
  ./run_process_chunks.sh [max_parallel] [total_primaries] [max_retries] [primaries_per_process]

Arguments:
  max_parallel           Maximum simulator processes running at once (default: 8)
  total_primaries        Total primaries across all chunks (default: 500000)
  max_retries            Retries for each failed chunk (default: 1)
  primaries_per_process  Maximum primaries handled by one simulator process
                         (default: 50000)

Each chunk is run by a fresh g4cmpQuasiparticle process. When that process
exits, the operating system recovers all memory it retained. Failed chunks
are retried independently with new deterministic seeds.

Example:
  env -u G4LATTICEDATA QP_BUILD_DIR="$PWD/QP-build-release" \
    ./run_process_chunks.sh 8 33333333 5 50000
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MAX_PARALLEL="${1:-8}"
TOTAL_PRIMARIES="${2:-500000}"
MAX_RETRIES="${3:-1}"
PRIMARIES_PER_PROCESS="${4:-50000}"

if (( $# > 4 )); then
  echo "Error: too many arguments." >&2
  usage >&2
  exit 2
fi

if [[ ! "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: max_parallel must be a positive integer." >&2
  exit 2
fi

if [[ ! "$TOTAL_PRIMARIES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: total_primaries must be a positive integer." >&2
  exit 2
fi

if [[ ! "$MAX_RETRIES" =~ ^[0-9]+$ ]]; then
  echo "Error: max_retries must be a non-negative integer." >&2
  exit 2
fi

if [[ ! "$PRIMARIES_PER_PROCESS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: primaries_per_process must be a positive integer." >&2
  exit 2
fi

if [[ ! -x "$EXE" ]]; then
  echo "Error: executable not found at $EXE" >&2
  echo "Set QP_BUILD_DIR or build the executable first." >&2
  exit 2
fi

if [[ ! -f "$BASE_MACRO" ]]; then
  echo "Error: macro not found at $BASE_MACRO" >&2
  exit 2
fi

# Resolve the lattice data before workers change to their output directories.
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

CHUNK_COUNT=$(((TOTAL_PRIMARIES + PRIMARIES_PER_PROCESS - 1) / PRIMARIES_PER_PROCESS))
ACTIVE_WORKERS=$MAX_PARALLEL
if (( ACTIVE_WORKERS > CHUNK_COUNT )); then
  ACTIVE_WORKERS=$CHUNK_COUNT
fi

RUN_TAG="process_chunks_$(date +%Y%m%d_%H%M%S)_$$"
RUN_DIR="$ROOT/parallel_runs/$RUN_TAG"
mkdir -p "$RUN_DIR"

printf '%s\n' \
  "total_primaries=$TOTAL_PRIMARIES" \
  "primaries_per_process=$PRIMARIES_PER_PROCESS" \
  "chunk_count=$CHUNK_COUNT" \
  "max_parallel=$MAX_PARALLEL" \
  "active_workers=$ACTIVE_WORKERS" \
  "max_retries=$MAX_RETRIES" \
  "build_dir=$BUILD_DIR" \
  "lattice_data=$LATTICE_DATA" > "$RUN_DIR/run_config.txt"

echo "Starting $CHUNK_COUNT process-isolated chunks for $TOTAL_PRIMARIES total primaries"
echo "Primaries per process: at most $PRIMARIES_PER_PROCESS"
echo "Concurrent simulator processes: $ACTIVE_WORKERS"
echo "Retries per failed chunk: $MAX_RETRIES"
echo "Results directory: $RUN_DIR"

make_chunk_macro() {
  local output_file="$1"
  local count="$2"
  local seed1="$3"
  local seed2="$4"

  awk \
    -v count="$count" \
    -v seed1="$seed1" \
    -v seed2="$seed2" '
      { lines[NR] = $0 }
      /^\/gps\/number[[:space:]]+[0-9]+([[:space:]]|$)/ {
        final_number_line = NR
      }
      /^\/run\/beamOn[[:space:]]+[0-9]+([[:space:]]|$)/ {
        final_beamon_line = NR
      }
      END {
        if (!final_number_line || !final_beamon_line) exit 20

        for (i = 1; i <= NR; ++i) {
          if (lines[i] ~ /^\/random\/setSeeds[[:space:]]+/) {
            print "/random/setSeeds " seed1 " " seed2
          } else if (i == final_number_line) {
            print "/gps/number " count
          } else if (i == final_beamon_line) {
            print "/run/beamOn 1"
          } else {
            print lines[i]
          }
        }
      }
    ' "$BASE_MACRO" > "$output_file"
}

run_chunk() {
  local chunk_index="$1"
  local chunk_dir="$RUN_DIR/chunk_$chunk_index"
  local count=$PRIMARIES_PER_PROCESS
  local attempt attempt_dir seed1 seed2 status output_name

  if (( chunk_index == CHUNK_COUNT - 1 )); then
    count=$((TOTAL_PRIMARIES - chunk_index * PRIMARIES_PER_PROCESS))
  fi

  mkdir -p "$chunk_dir"

  for ((attempt = 0; attempt <= MAX_RETRIES; attempt++)); do
    attempt_dir="$chunk_dir/attempt_$attempt"
    mkdir -p "$attempt_dir"

    # Chunk and attempt offsets give every invocation a reproducible seed pair.
    seed1=$((123456 + chunk_index + attempt * CHUNK_COUNT))
    seed2=$((567890 + 17 * chunk_index + 104729 * attempt))

    if ! make_chunk_macro "$attempt_dir/run.mac" "$count" "$seed1" "$seed2"; then
      echo "Error: failed to generate macro for chunk_$chunk_index." >&2
      return 2
    fi

    ln -sfn "attempt_$attempt/run.mac" "$chunk_dir/run.mac"
    ln -sfn "attempt_$attempt/run.log" "$chunk_dir/run.log"

    echo "  chunk_$chunk_index attempt_$attempt: $count primaries, seeds $seed1 $seed2"
    status=0
    (
      cd "$attempt_dir" || exit 1
      export G4LATTICEDATA="$LATTICE_DATA"
      "$EXE" run.mac > run.log 2>&1
    ) || status=$?

    if (( status == 0 )); then
      echo "$attempt" > "$chunk_dir/successful_attempt.txt"
      for output_name in QuasiparticleStepInformationFile.txt phonon_hits.txt; do
        if [[ -e "$attempt_dir/$output_name" ]]; then
          ln -sfn "attempt_$attempt/$output_name" "$chunk_dir/$output_name"
        fi
      done
      echo "  chunk_$chunk_index complete"
      return 0
    fi

    echo "Warning: chunk_$chunk_index attempt_$attempt failed with exit status $status" >&2
    if (( attempt < MAX_RETRIES )); then
      echo "  Retrying chunk_$chunk_index in a fresh process..." >&2
    fi
  done

  echo "Error: chunk_$chunk_index exhausted all attempts." >&2
  return "$status"
}

run_worker_slot() {
  local slot="$1"
  local chunk_index
  local failed=0

  # Fixed striding provides a simple queue with at most ACTIVE_WORKERS live
  # simulators. Each iteration waits for the prior process in this slot to exit.
  for ((chunk_index = slot; chunk_index < CHUNK_COUNT; chunk_index += ACTIVE_WORKERS)); do
    if ! run_chunk "$chunk_index"; then
      failed=1
    fi
  done

  return "$failed"
}

PIDS=()
for ((slot = 0; slot < ACTIVE_WORKERS; slot++)); do
  run_worker_slot "$slot" &
  PIDS+=("$!")
done

FAILED=0
for ((slot = 0; slot < ACTIVE_WORKERS; slot++)); do
  if ! wait "${PIDS[$slot]}"; then
    FAILED=1
  fi
done

if (( FAILED != 0 )); then
  echo "One or more chunks failed. Outputs were not merged." >&2
  echo "Partial results and logs remain in: $RUN_DIR" >&2
  exit 1
fi

merge_csv_outputs() {
  local output_name="$1"
  shift
  local output_file="$RUN_DIR/$output_name"
  local batch_size=500
  local start=0
  local print_header=1
  local -a batch

  # Keep each awk invocation comfortably below the operating system's
  # argument-size limit, even when a run contains tens of thousands of files.
  : > "$output_file" || return 1
  while (( start < $# )); do
    batch=("${@:start+1:batch_size}")
    awk -v print_header="$print_header" '
      FNR == 1 {
        if (print_header) {
          print "Chunk," $0
          print_header = 0
        }
        next
      }
      {
        count = split(FILENAME, path, "/")
        chunk = path[count - 1]
        sub(/^chunk_/, "", chunk)
        print chunk "," $0
      }
    ' "${batch[@]}" >> "$output_file" || return 1
    print_header=0
    ((start += batch_size))
  done
}

QP_FILES=()
HIT_FILES=()
for ((chunk_index = 0; chunk_index < CHUNK_COUNT; chunk_index++)); do
  chunk_dir="$RUN_DIR/chunk_$chunk_index"
  if [[ -e "$chunk_dir/QuasiparticleStepInformationFile.txt" ]]; then
    QP_FILES+=("$chunk_dir/QuasiparticleStepInformationFile.txt")
  fi
  if [[ -e "$chunk_dir/phonon_hits.txt" ]]; then
    HIT_FILES+=("$chunk_dir/phonon_hits.txt")
  fi
done

if (( ${#QP_FILES[@]} > 0 )); then
  if ! merge_csv_outputs combined_qp_results.csv "${QP_FILES[@]}"; then
    echo "Error: failed to merge quasiparticle outputs." >&2
    exit 1
  fi
fi

if (( ${#HIT_FILES[@]} > 0 )); then
  if ! merge_csv_outputs combined_phonon_hits.csv "${HIT_FILES[@]}"; then
    echo "Error: failed to merge phonon-hit outputs." >&2
    exit 1
  fi
fi

echo "All $CHUNK_COUNT chunks completed successfully."
echo "Combined results:"
if (( ${#QP_FILES[@]} > 0 )); then
  echo "  $RUN_DIR/combined_qp_results.csv"
fi
if (( ${#HIT_FILES[@]} > 0 )); then
  echo "  $RUN_DIR/combined_phonon_hits.csv"
fi
