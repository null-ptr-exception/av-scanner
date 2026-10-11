# Roadmap

Ideas that are measured or designed but not scheduled.

## Batch Trend Micro on-demand scans

**Why.** Each `dsa_scan` call costs the agent's `ds_agent` process about 0.2–0.3 CPU-seconds, whatever the file. On a 2 vCPU VM, `ds_agent` saturates one core at about 4 scans/s. Above that, scans queue up and fail with exit 253 ("Socket reset").

**Measured** (agent 20.0.3, 2 vCPU, 20 fresh 1 MB zips, `scripts/perf-test.sh` and a direct comparison on the VM):

| Method | `ds_agent` CPU per file |
|---|---|
| One `dsa_scan` call per file (sequential or parallel) | 0.19–0.35 s |
| One `dsa_scan` call for a directory of 20 files | 0.01–0.08 s |

So batching is about 4–20× cheaper per file.

**Design outline.**

- Collect uploads that arrive within a short window (e.g. 50–100 ms) into a per-batch directory under the scan directory.
- Run one `dsa_scan --target <dir> --json --log /dev/stderr` per batch.
- Map results back to each upload by file name:
  - **Clean:** only when the batch scanned every file, skipped none, found no infection and exited 0.
  - **Infected:** only the files listed in `infectedFiles`.
  - **Skipped files or errors:** the JSON does not say which file was skipped, so fail the whole batch, or rescan its files one by one. Never assume clean.
- Trade-off: each upload waits up to one batching window longer.

**Open question.** How a batch reports an infected file (`infectedFiles[].fileName`) has not been verified on a real agent. The agent's real-time scan removes an EICAR file before a batch can scan it. Verifying it needs a directory excluded from real-time scanning in the agent policy.

## Limit concurrent Trend Micro scans

A cap on concurrent `dsa_scan` calls in the driver would not raise throughput. It would make requests above the agent's capacity wait instead of failing. Batching above would make it less important.
