#!/usr/bin/env bash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${QP_BUILD_DIR:-$ROOT/QP-build}"
EXE="$BUILD_DIR/g4cmpQuasiparticle"
CMAKE_CACHE="$BUILD_DIR/CMakeCache.txt"
BASE_MACRO="$ROOT/G4Macros/quasiparticle_resonator_targeted.mac"

# Usage: ./run_parallel.sh [number_of_jobs] [total_primaries] [max_retries] [batch_size]
NJOBS="${1:-16}"
TOTAL_PRIMARIES="${2:-500000}"
MAX_RETRIES="${3:-1}"
BATCH_SIZE="${4:-1000}"

if (( $# > 4 )); then
  echo "Error: too many arguments." >&2
  echo "Usage: ./run_parallel.sh [number_of_jobs] [total_primaries] [max_retries] [batch_size]" >&2
  exit 2
fi

if [[ ! "$NJOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: number_of_jobs must be a positive integer." >&2
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

if [[ ! "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: batch_size must be a positive integer." >&2
  exit 2
fi

if (( TOTAL_PRIMARIES < NJOBS )); then
  echo "Error: total_primaries must be at least number_of_jobs." >&2
  exit 2
fi

if [[ ! -x "$EXE" ]]; then
  echo "Error: executable not found at $EXE" >&2
  echo "Build it first with: cmake --build QP-build -j" >&2
  exit 2
fi

if [[ ! -f "$BASE_MACRO" ]]; then
  echo "Error: macro not found at $BASE_MACRO" >&2
  exit 2
fi

# G4CMP defaults G4LATTICEDATA to the relative path ./CrystalMaps.  Each
# worker runs in its own output directory, so resolve that data directory to
# an absolute path before changing directories.
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

# A unique batch directory prevents fixed output filenames from different
# launches from overwriting or appending to one another.
RUN_TAG="$(date +%Y%m%d_%H%M%S)_$$"
RUN_DIR="$ROOT/parallel_runs/$RUN_TAG"
mkdir -p "$RUN_DIR"

BASE_COUNT=$((TOTAL_PRIMARIES / NJOBS))
REMAINDER=$((TOTAL_PRIMARIES % NJOBS))
PIDS=()

echo "Starting $NJOBS jobs for $TOTAL_PRIMARIES total primaries"
echo "Maximum primaries per event: $BATCH_SIZE"
echo "Failed jobs will be retried up to $MAX_RETRIES time(s) with new seeds"
echo "Results directory: $RUN_DIR"
echo "Lattice data: $LATTICE_DATA"

make_worker_macro() {
  local output_file="$1"
  local count="$2"
  local seed1="$3"
  local seed2="$4"
  local full_events=$((count / BATCH_SIZE))
  local tail_primaries=$((count % BATCH_SIZE))

  awk \
    -v seed1="$seed1" \
    -v seed2="$seed2" \
    -v batch_size="$BATCH_SIZE" \
    -v full_events="$full_events" \
    -v tail_primaries="$tail_primaries" '
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
            if (full_events > 0) {
              print "/gps/number " batch_size
              print "/run/beamOn " full_events
            }
            if (tail_primaries > 0) {
              print "/gps/number " tail_primaries
              print "/run/beamOn 1"
            }
          } else if (i != final_beamon_line) {
            print lines[i]
          }
        }
      }
    ' "$BASE_MACRO" > "$output_file"
}

for ((i = 0; i < NJOBS; i++)); do
  JOB_DIR="$RUN_DIR/job_$i"
  mkdir -p "$JOB_DIR"

  COUNT=$BASE_COUNT
  if (( i < REMAINDER )); then
    COUNT=$((COUNT + 1))
  fi

  (
    for ((attempt = 0; attempt <= MAX_RETRIES; attempt++)); do
      ATTEMPT_DIR="$JOB_DIR/attempt_$attempt"
      mkdir -p "$ATTEMPT_DIR"

      # The attempt offset guarantees that a retry never reuses the failed
      # seed pair, while remaining reproducible from the job and attempt IDs.
      SEED1=$((123456 + i + attempt * NJOBS))
      SEED2=$((567890 + 17 * i + 104729 * attempt))

      if ! make_worker_macro "$ATTEMPT_DIR/run.mac" "$COUNT" \
        "$SEED1" "$SEED2"; then
        echo "Error: could not generate batched worker macro." >&2
        exit 2
      fi

      # Keep these convenient paths pointed at the latest attempt. Attempt
      # directories preserve earlier logs and any partial output for diagnosis.
      ln -sfn "attempt_$attempt/run.mac" "$JOB_DIR/run.mac"
      ln -sfn "attempt_$attempt/run.log" "$JOB_DIR/run.log"

      echo "  job_$i attempt_$attempt: seeds $SEED1 $SEED2"
      ATTEMPT_STATUS=0
      (
        cd "$ATTEMPT_DIR" || exit 1
        export G4LATTICEDATA="$LATTICE_DATA"
        "$EXE" run.mac > run.log 2>&1
      ) || ATTEMPT_STATUS=$?

      if (( ATTEMPT_STATUS == 0 )); then
        echo "$attempt" > "$JOB_DIR/successful_attempt.txt"
        for OUTPUT_NAME in QuasiparticleStepInformationFile.txt phonon_hits.txt; do
          if [[ -e "$ATTEMPT_DIR/$OUTPUT_NAME" ]]; then
            ln -sfn "attempt_$attempt/$OUTPUT_NAME" "$JOB_DIR/$OUTPUT_NAME"
          fi
        done
        exit 0
      fi

      echo "Warning: job_$i attempt_$attempt failed with exit status $ATTEMPT_STATUS" >&2
      if (( attempt < MAX_RETRIES )); then
        echo "  Retrying job_$i with a new seed pair..." >&2
      fi
    done

    exit "$ATTEMPT_STATUS"
  ) &
  PIDS+=("$!")
  FULL_EVENTS=$((COUNT / BATCH_SIZE))
  TAIL_PRIMARIES=$((COUNT % BATCH_SIZE))
  if (( TAIL_PRIMARIES > 0 )); then
    echo "  job_$i: $COUNT primaries in $FULL_EVENTS full event(s)" \
         "plus a $TAIL_PRIMARIES-primary tail, PID ${PIDS[-1]}"
  else
    echo "  job_$i: $COUNT primaries in $FULL_EVENTS full event(s)," \
         "PID ${PIDS[-1]}"
  fi
done

FAILED=0
for ((i = 0; i < NJOBS; i++)); do
  if ! wait "${PIDS[$i]}"; then
    echo "Error: job_$i failed; see $RUN_DIR/job_$i/run.log" >&2
    FAILED=1
  fi
done

if (( FAILED != 0 )); then
  echo "One or more jobs failed. Outputs were not merged." >&2
  exit 1
fi

merge_csv_outputs() {
  local output_name="$1"
  shift

  awk '
    FNR == 1 {
      if (!printed_header) {
        print "Job," $0
        printed_header = 1
      }
      next
    }
    {
      count = split(FILENAME, path, "/")
      job = path[count - 1]
      sub(/^job_/, "", job)
      print job "," $0
    }
  ' "$@" > "$RUN_DIR/$output_name"
}

QP_FILES=("$RUN_DIR"/job_*/QuasiparticleStepInformationFile.txt)
HIT_FILES=("$RUN_DIR"/job_*/phonon_hits.txt)

if [[ -e "${QP_FILES[0]}" ]]; then
  merge_csv_outputs combined_qp_results.csv "${QP_FILES[@]}"
fi

if [[ -e "${HIT_FILES[0]}" ]]; then
  merge_csv_outputs combined_phonon_hits.csv "${HIT_FILES[@]}"
fi

echo "All jobs completed successfully."
echo "Combined results:"
echo "  $RUN_DIR/combined_qp_results.csv"
echo "  $RUN_DIR/combined_phonon_hits.csv"
