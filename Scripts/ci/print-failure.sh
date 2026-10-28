#!/bin/bash
# Prints the part of each CI log that explains a failure: the failing lines first, then the end of
# the log. Jobs write test and build output to files under build/, so without this the job log
# shows only an exit code and the reason is hidden in an uploaded artifact.
set -uo pipefail
for LOG in "$@"; do
  if [[ ! -f "$LOG" ]]; then
    echo "No log at $LOG; the step that writes it did not run."
    continue
  fi
  echo "=== Failing lines in $LOG ==="
  grep -n -E '✘|error:|Test Case .* failed|\*\* (TEST|BUILD|ARCHIVE) FAILED \*\*|Fatal error' "$LOG" | head -n 80 || true
  echo "=== Last 60 lines of $LOG ==="
  tail -n 60 "$LOG"
done
