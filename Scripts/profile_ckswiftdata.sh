#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
RECORDS="${RECORDS:-5000}"
ITERATIONS="${ITERATIONS:-5}"
PAGE_SIZE="${PAGE_SIZE:-250}"
WARMUP="${WARMUP:-1}"
EDIT_STRIDE="${EDIT_STRIDE:-10}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${OUTPUT_DIR:-${TMPDIR:-/tmp}/ckswiftdata-profile-${STAMP}}"

mkdir -p "$OUTPUT_DIR"

swift build -c release --product CKSwiftDataPerformance >/dev/null
BIN_DIR="$(swift build -c release --product CKSwiftDataPerformance --show-bin-path)"
BIN="$BIN_DIR/CKSwiftDataPerformance"
TRACE="$OUTPUT_DIR/time-profile.trace"

echo "Building release benchmark: $BIN"
echo "Recording trace: $TRACE"

xctrace record \
    --template "Time Profiler" \
    --instrument os_signpost \
    --no-prompt \
    --output "$TRACE" \
    --target-stdout "$OUTPUT_DIR/workload.txt" \
    --launch -- "$BIN" \
        --records "$RECORDS" \
        --iterations "$ITERATIONS" \
        --page-size "$PAGE_SIZE" \
        --warmup "$WARMUP" \
        --edit-stride "$EDIT_STRIDE"

xctrace export "$TRACE" --toc --output "$OUTPUT_DIR/toc.xml"
xctrace export "$TRACE" \
    --xpath '/trace-toc/run[@number="1"]/data/table' \
    --output "$OUTPUT_DIR/tables.xml"

cat <<EOF

Profile complete.
  Workload: $OUTPUT_DIR/workload.txt
  Trace:    $TRACE
  TOC:      $OUTPUT_DIR/toc.xml
  Tables:   $OUTPUT_DIR/tables.xml

Open the trace in Instruments and inspect the measured Fetch/Save signposts.
For the Time Profiler call tree, use Separate by Thread, Hide System Libraries,
and Invert Call Tree before copying the relevant interval for analysis.
EOF
