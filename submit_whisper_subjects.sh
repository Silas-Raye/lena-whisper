#!/bin/bash
# submit_whisper_subjects.sh — transcribe the participants in participant_ids.txt.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/submit_whisper_subjects.sh
#
# Submits one SLURM array job with one task per participant. Participants
# that are already done, or whose recording isn't on ACCRE, are skipped. Rerun
# this after each round of jobs until status.sh shows every participant done.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$LW_DIR"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"   # shorter path for messages

if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    echo "[X] Setup hasn't been run yet. Run: bash ${SHOW_DIR}/setup.sh"
    exit 1
fi

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    echo "    Add one ID per line (for example 1006): nano ${SHOW_DIR}/participant_ids.txt"
    exit 1
fi

mkdir -p logs runs
# Freeze the list for this submission, so editing participant_ids.txt while
# jobs wait in the queue can't change which participant a task runs.
snapshot="runs/participants_$(date +%Y%m%d_%H%M%S).txt"
: > "$snapshot"

echo "[*] Checking participants in participant_ids.txt..."
n_queued=0
while IFS= read -r pid; do
    read -r state n_done n_chunks <<< "$(participant_status "$pid")"
    case "$state" in
        done)
            printf "    %-16s done (%s/%s chunks), skipping\n" "$pid" "$n_done" "$n_chunks" ;;
        missing)
            printf "    %-16s no recording in %s, skipping\n" "$pid" "$RAW_DIR" ;;
        *)
            n_queued=$((n_queued + 1))
            echo "$pid" >> "$snapshot"
            case "$state" in
                new)          note="not started" ;;
                chunking)     note="chunking stopped partway; will redo it" ;;
                transcribing) note="${n_done}/${n_chunks} chunks done" ;;
            esac
            printf "    %-16s task %-3s %s\n" "$pid" "$n_queued" "$note" ;;
    esac
done < <(recording_ids "$LW_IDS_FILE")

if [ "$n_queued" -eq 0 ]; then
    rm -f "$snapshot"
    echo "[✓] Nothing to submit. Check details with: bash ${SHOW_DIR}/status.sh"
    exit 0
fi

# Warn about earlier rounds still in the queue.
n_existing=$( { squeue --me -h -n whisper_subject -r 2>/dev/null || true; } | wc -l)
if [ "$n_existing" -gt 0 ]; then
    echo
    echo "[!] You already have ${n_existing} whisper task(s) queued or running."
    echo "    New tasks for the same participants continue where those stop."
    read -r -p "    Submit another round anyway? [y/N] " answer || answer=""
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        rm -f "$snapshot"
        echo "    Not submitted."
        exit 0
    fi
fi

sbatch_args=(
    --account="$SLURM_ACCOUNT"
    --partition="$SLURM_PARTITION"
    --gres="$SLURM_GRES"
    --time="$SLURM_TIME"
    --cpus-per-task="$SLURM_CPUS"
    --mem="$SLURM_MEM"
    --array="1-${n_queued}%${MAX_PARALLEL}"
    --output="${LW_DIR}/logs/%x_%A_%a.log"
)
if [ -n "$SLURM_QOS" ]; then
    sbatch_args+=(--qos="$SLURM_QOS")
fi

job_id=$(sbatch --parsable "${sbatch_args[@]}" run_whisper_subject.sh "${LW_DIR}/${snapshot}")
job_id="${job_id%%;*}"

echo
echo "[✓] Submitted job ${job_id} with ${n_queued} task(s)."
echo "    Progress: bash ${SHOW_DIR}/status.sh"
echo "    Queue:    squeue --me -r"
echo "    Logs:     ${SHOW_DIR}/logs/whisper_subject_${job_id}_<task>.log"
if [[ "$SLURM_QOS" == debug* ]]; then
    echo
    echo "    Each task stops after ${SLURM_TIME} and saves every finished chunk."
    echo "    When the queue is empty, run this script again to continue."
fi
