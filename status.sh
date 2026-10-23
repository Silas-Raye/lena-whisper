#!/bin/bash
# status.sh — show transcription progress for each participant in
# participant_ids.txt, plus any whisper jobs in the queue.
#
# Usage: bash ~/lena-whisper/status.sh

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    exit 1
fi

printf "%-16s %-14s %s\n" "PARTICIPANT" "STATUS" "CHUNKS TRANSCRIBED"
n_left=0
n_missing=0
while IFS= read -r pid; do
    read -r state n_done n_chunks <<< "$(participant_status "$pid")"
    case "$state" in
        done)         label="done" ;;
        transcribing) label="in progress" ;;
        chunking)     label="chunking" ;;
        new)          label="not started" ;;
        missing)      label="no recording" ;;
    esac
    if [ "$n_chunks" -gt 0 ] && [ "$state" != "chunking" ]; then
        chunks="${n_done} / ${n_chunks}"
    else
        chunks="-"
    fi
    printf "%-16s %-14s %s\n" "$pid" "$label" "$chunks"
    if [ "$state" = "missing" ]; then
        n_missing=$((n_missing + 1))
    elif [ "$state" != "done" ]; then
        n_left=$((n_left + 1))
    fi
done < <(clean_ids "$LW_IDS_FILE")

echo
if [ "$n_missing" -gt 0 ]; then
    echo "${n_missing} participant(s) have no recording in ${RAW_DIR}."
    echo "Upload them (README: Copy files between your computer and ACCRE)."
    echo
fi
jobs=$(squeue --me -h -r -n whisper_subject -o "%.18i %.8T %.10M %.10L %R" 2>/dev/null || true)
if [ -n "$jobs" ]; then
    echo "Whisper tasks in the queue:"
    printf "%18s %8s %10s %10s %s\n" "JOBID" "STATE" "ELAPSED" "TIME_LEFT" "NODE/REASON"
    echo "$jobs"
elif [ "$n_left" -gt 0 ]; then
    echo "No whisper tasks in the queue. To continue, run:"
    echo "    bash ${SHOW_DIR}/submit_whisper_subjects.sh"
elif [ "$n_missing" -eq 0 ]; then
    echo "Every participant is done. Copy the transcripts back to the lab"
    echo "server (README: Copy files between your computer and ACCRE)."
fi
