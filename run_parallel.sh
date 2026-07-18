#!/usr/bin/env bash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE="$ROOT/QP-build/g4cmpQuasiparticle"
BASE_MACRO="$ROOT/G4Macros/quasiparticle_resonator_targeted.mac"
CMAKE_CACHE="$ROOT/QP-build/CMakeCache.txt"

# Usage: ./run_parallel.sh [number_of_jobs] [total_primaries] [max_retries]
NJOBS="${1:-16}"
TOTAL_PRIMARIES="${2:-500000}"
MAX_RETRIES="${3:-1}"

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
echo "Failed jobs will be retried up to $MAX_RETRIES time(s) with new seeds"
echo "Results directory: $RUN_DIR"
echo "Lattice data: $LATTICE_DATA"

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

      sed \
        -e "s|^/random/setSeeds .*|/random/setSeeds $SEED1 $SEED2|" \
        -e "s|^/gps/number 500000$|/gps/number $COUNT|" \
        "$BASE_MACRO" > "$ATTEMPT_DIR/run.mac"

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
  echo "  job_$i: $COUNT primaries, PID ${PIDS[-1]}"
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
