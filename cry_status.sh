#!/bin/bash
# cry_status.sh — show cry detection progress for each participant in
# participant_ids.txt, plus any cry detection jobs in the queue.
#
# Usage: bash ~/lena-whisper/cry_status.sh

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    exit 1
fi

queued=$(queued_participants cry_subject)

printf "%-16s %-20s %s\n" "PARTICIPANT" "CRY DETECTION" "CRYING DETECTED"
n_left=0
n_missing=0
while IFS= read -r pid; do
    crying="-"
    case "$(cry_state "$pid")" in
        done)
            label="done"
            # Rows after the header, and how many say 1 (crying)
            crying=$(awk -F, 'NR > 1 { n++; c += $2 } END {
                printf "%.1f min of %.1f h", c / 60, n / 3600 }' "$(cry_path "$pid")") ;;
        missing)
            label="no recording"
            n_missing=$((n_missing + 1)) ;;
        waiting)
            label="waiting for chunks"
            n_left=$((n_left + 1)) ;;
        ready)
            if grep -qxF "$pid" <<< "$queued"; then
                label="queued or running"
            else
                label="not started"
            fi
            n_left=$((n_left + 1)) ;;
    esac
    printf "%-16s %-20s %s\n" "$pid" "$label" "$crying"
done < <(clean_ids "$LW_IDS_FILE")

echo
if [ "$n_missing" -gt 0 ]; then
    echo "${n_missing} participant(s) have no recording in ${RAW_DIR}."
    echo "Upload them (README: Copy files between your computer and ACCRE)."
    echo
fi
jobs=$(squeue --me -h -r -n cry_subject -o "%.18i %.8T %.10M %.10L %R" 2>/dev/null || true)
if [ -n "$jobs" ]; then
    echo "Cry detection tasks in the queue:"
    printf "%18s %8s %10s %10s %s\n" "JOBID" "STATE" "ELAPSED" "TIME_LEFT" "NODE/REASON"
    echo "$jobs"
elif [ "$n_left" -gt 0 ]; then
    echo "No cry detection tasks in the queue. To start the rest, run the"
    echo "following command; 'waiting for chunks' means the first Whisper job"
    echo "hasn't cut that recording into chunks yet:"
    echo "    bash ${SHOW_DIR}/submit_cry_subjects.sh"
    echo "If a participant's task already ran, its log says why it stopped:"
    echo "    ls -t ${SHOW_DIR}/logs/cry_subject_* | head"
elif [ "$n_missing" -eq 0 ]; then
    echo "Cry detection is done for every participant. When Whisper is done too,"
    echo "combine the results: bash ${SHOW_DIR}/combine_subjects.sh"
fi
