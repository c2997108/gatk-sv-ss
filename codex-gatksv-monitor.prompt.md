# Autonomous GATK-SV SGE monitor

You are running non-interactively from:

`/SSD_ARRAY/gatk-sv-1.1/gatk-sv`

Objective: keep the local SGE GATK-SV run driven by `./run-cramdir-batches-joint.sh all` moving until all discovered `cram`, `cram2`, `cram3`, ... batches and the final joint workflow have completed successfully.

Current required run mode:

- `GATKSV_USE_MELT=false`
- `GATKSV_USE_SCRAMBLE=true`
- `cromwell-sge.conf` should retain `concurrent-job-limit = 100` unless there is a clear reason to change it.
- Do not use MELT. SCRAMble is the mobile element caller for this run.

Every invocation must do the following:

1. Gather current status with `./codex-gatksv-monitor-check.sh sge-cramdir-joint/codex-monitor/snapshot.latest.md`, plus any targeted commands needed (`screen -ls`, `qstat -u "$USER"`, latest Cromwell logs, metadata JSONs).
2. Append a concise entry to `sge-cramdir-joint/codex-monitor/status.md` with the exact time, current state, workflow/log IDs, actions taken, and next expected state.
3. If a Cromwell run or `./run-cramdir-batches-joint.sh all` is still active, do not restart it. Summarize progress and exit.
4. If the analysis is complete, verify that all batch metadata listed in `sge-cramdir-joint/batch_metadata.tsv` have `.status == "Succeeded"` and that the latest joint metadata has `.status == "Succeeded"`. Record the important output paths, then create `sge-cramdir-joint/codex-monitor/COMPLETE`.
5. If it failed, diagnose the latest failing workflow from the logs. Fix only the narrow, evidenced cause. Examples:
   - For gzip CRC/length errors involving cached or produced `*.tsv.gz` files, map the failing `inputs/...` symlink to the real source with `readlink -f`, test with `gzip -t`, write a manifest under `sge-cramdir-joint/cache-cleanup/<timestamp>-<reason>/`, and move only the clearly implicated file(s) there before rerunning.
   - For script/config errors, patch the smallest local script/config needed, preserving existing patterns.
   - Never delete broad directories such as `cromwell-executions`, `sge-cramdir-joint`, `cram`, `cram2`, or `cram3`.
   - Never use `git reset`, `git checkout --`, or broad cleanup commands.
6. If no run is active and the workflow is not complete, start a new run in a detached screen session. Use this pattern so the return code is real:

```bash
cd /SSD_ARRAY/gatk-sv-1.1/gatk-sv
ts="$(date +%Y%m%d-%H%M%S)"
session="gatksv_auto_${ts}"
log="/SSD_ARRAY/gatk-sv-1.1/gatk-sv/sge-cramdir-joint/run-all.${ts}.screen.log"
RUN_LOG="$log" screen -dmS "$session" bash -lc '
cd /SSD_ARRAY/gatk-sv-1.1/gatk-sv
export GATKSV_USE_MELT=false
export GATKSV_USE_SCRAMBLE=true
set -o pipefail
{
  echo "[start at $(date)]"
  echo "[cwd $(pwd)]"
  echo "[cmd ./run-cramdir-batches-joint.sh all]"
  echo "[env GATKSV_USE_MELT=${GATKSV_USE_MELT} GATKSV_USE_SCRAMBLE=${GATKSV_USE_SCRAMBLE}]"
} | tee "$RUN_LOG"
./run-cramdir-batches-joint.sh all 2>&1 | tee -a "$RUN_LOG"
rc=${PIPESTATUS[0]}
echo "[done rc=${rc} at $(date)]" | tee -a "$RUN_LOG"
exit "$rc"
'
```

7. If you cannot make progress without human input, write `sge-cramdir-joint/codex-monitor/BLOCKED` with a concise reason and append the same reason to `status.md`.

Completion criteria:

- `./run-cramdir-batches-joint.sh all` has produced successful batch metadata for every row in `sge-cramdir-joint/batches.tsv`.
- `prepare-joint` and `run-joint` have completed.
- The latest `metadata.GATKSVPipelineJointBatch.*.recovered.json` has `.status == "Succeeded"`.
- The final joint output paths are recorded in `sge-cramdir-joint/codex-monitor/status.md`.

Be conservative. Prefer waiting when work is active. Only rerun after confirming there is no active Cromwell process, no active screen session for the current run, and no relevant SGE jobs still running.

Performance guardrails:

- Do not run broad recursive scans such as `find .`, `rg` over the entire repository, or recursive `du` while the pipeline is active.
- Prefer the monitor snapshot and the known run paths under `sge-cramdir-joint`.
- If a file search is necessary, restrict it to the newest workflow/log directory or use `-maxdepth` and narrow filename patterns.
- When the pipeline is clearly active, record the active state and exit promptly.
