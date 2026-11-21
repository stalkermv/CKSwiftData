# CKSwiftData performance profiling

This package is a SwiftPM library rather than an app project, so the
profiling entry point is a deterministic executable:
`CKSwiftDataPerformance`. It exercises typed paged fetches and saves against
the in-memory CloudKit client. The workload isolates local context, snapshot,
schema, and value-bridging costs from network latency while still using the
same public context APIs as the library.

Profile the benchmark with the Time Profiler instrument:

```bash
./Scripts/profile_ckswiftdata.sh
```

The script builds the benchmark in release mode, records the Time Profiler and
`os_signpost` instruments with `xctrace`, and exports the trace table of
contents and raw tables to a timestamped directory under `/tmp`. Override the
workload without editing the source:

```bash
RECORDS=10000 ITERATIONS=8 PAGE_SIZE=500 \
  OUTPUT_DIR=/tmp/ckswiftdata-profile-large \
  ./Scripts/profile_ckswiftdata.sh
```

The benchmark prints a tab-separated wall-clock summary in `workload.txt` and
emits `Fetch`, `Save`, and `Warmup` intervals. In Instruments, select the
measured signpost interval, then apply these Time Profiler call-tree filters:

- Separate by Thread
- Hide System Libraries
- Invert Call Tree

Copy the signpost interval metadata together with the filtered Time Profiler
call tree for a profiling report. Re-run the exact same
workload after a change and compare both wall-clock phase timings and the
weighted call tree. A trace from this fake client is not a CloudKit network
benchmark; validate network and device behavior separately on a representative
physical device before making product claims.

## XCTest performance baseline

`CKSwiftDataPerformanceTests` is a separate XCTest target for repeatable
clock, CPU, and memory measurements of the synchronous snapshot conversion
path. Run it from Xcode, select the performance test, and use the measurement
result to set a baseline and maximum standard deviation. See Apple's
[Writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)
documentation for the `measure(metrics:block:)` workflow and available
`XCTMetric` types. Apple recommends a Release test configuration with code
coverage and runtime sanitizers disabled for representative performance
measurements.

Run it with strict concurrency checking:

```bash
swift test -c release --filter CKSwiftDataPerformanceTests \
  --scratch-path /tmp/ckswiftdata-performance-tests \
  -Xswiftc -strict-concurrency=complete
```

This command is a measurement harness, not a checked-in regression gate:
the package does not contain an Xcode `.xcbaseline` file. Set and review the
baseline and maximum standard deviation from Xcode when turning this into a
project-specific regression check.

The paged `CloudModelContext.fetch` path remains in the release executable and
`xctrace` workflow because XCTest's `measure(metrics:block:)` measures a
synchronous block. The XCTest target therefore guards the hottest synchronous
primitive, while the executable preserves the end-to-end async paging result.
