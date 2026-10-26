#!/bin/bash
# submit_cry_subjects.sh — run cry detection for the participants in participant_ids.txt.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/submit_cry_subjects.sh
#
# Submits one SLURM array job with one CPU task per participant. Cry
# detection runs YAMNet on the 5-minute chunks that the first Whisper job cuts
# from each recording, so it can start once transcription has started, and
# runs alongside it. Participants that are already done or queued, or whose
# recording isn't chunked yet, are skipped.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$LW_DIR"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"   # shorter path for messages

if [ ! -f "${CRY_VENV_DIR}/bin/activate" ]; then
    echo "[X] Cry detection isn't set up yet. Run: bash ${SHOW_DIR}/setup.sh"
    exit 1
fi

if [ ! -f "${CRY_MODEL}/saved_model.pb" ]; then
    echo "[X] YAMNet isn't in ${CRY_MODEL/#"$HOME"/"~"}. It comes with the repository;"
    echo "    restore it with: git -C ${SHOW_DIR} checkout -- cry_model"
    exit 1
fi

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    echo "    Add one ID per line (for example 1243_029768): nano ${SHOW_DIR}/participant_ids.txt"
    exit 1
fi

mkdir -p logs runs
# Freeze the list for this submission, so editing participant_ids.txt while
# jobs wait in the queue can't change which participant a task runs.
snapshot="runs/cry_participants_$(date +%Y%m%d_%H%M%S).txt"
: > "$snapshot"

queued=$(queued_participants cry_subject)

echo "[*] Checking participants in participant_ids.txt..."
n_queued=0
while IFS= read -r pid; do
    case "$(cry_state "$pid")" in
        done)
            printf "    %-16s done, skipping\n" "$pid" ;;
        missing)
            printf "    %-16s no recording in %s, skipping\n" "$pid" "$RAW_DIR" ;;
        waiting)
            printf "    %-16s not chunked yet: run submit_whisper_subjects.sh first, skipping\n" "$pid" ;;
        ready)
            if grep -qxF "$pid" <<< "$queued"; then
                printf "    %-16s already queued or running, skipping\n" "$pid"
            else
                n_queued=$((n_queued + 1))
                echo "$pid" >> "$snapshot"
                printf "    %-16s task %s\n" "$pid" "$n_queued"
            fi ;;
    esac
done < <(clean_ids "$LW_IDS_FILE")

if [ "$n_queued" -eq 0 ]; then
    rm -f "$snapshot"
    echo "[✓] Nothing to submit. Check details with: bash ${SHOW_DIR}/cry_status.sh"
    exit 0
fi

# A queued task whose participant couldn't be read might be one of these.
if grep -qxF "?" <<< "$queued"; then
    echo
    echo "[!] You have cry detection tasks in the queue, and for some of them"
    echo "    it isn't clear which participant they're for (squeue --me -r)."
    read -r -p "    Submit anyway? [y/N] " answer || answer=""
    if [[ ! "$answer" =~ ^[Yy] ]]; then
        rm -f "$snapshot"
        echo "    Not submitted."
        exit 0
    fi
fi

sbatch_args=(
    --time="$CRY_SLURM_TIME"
    --cpus-per-task="$CRY_SLURM_CPUS"
    --mem="$CRY_SLURM_MEM"
    --array="1-${n_queued}%${MAX_PARALLEL}"
    --output="${LW_DIR}/logs/%x_%A_%a.log"
    --comment="${LW_DIR}/${snapshot}"   # lets status scripts tell which task is whose
)
if [ -n "$CRY_SLURM_ACCOUNT" ]; then
    sbatch_args+=(--account="$CRY_SLURM_ACCOUNT")
fi
if [ -n "$CRY_SLURM_PARTITION" ]; then
    sbatch_args+=(--partition="$CRY_SLURM_PARTITION")
fi

job_id=$(sbatch --parsable "${sbatch_args[@]}" run_cry_subject.sh "${LW_DIR}/${snapshot}")
job_id="${job_id%%;*}"

echo
echo "[✓] Submitted job ${job_id} with ${n_queued} task(s)."
echo "    Each task takes a few minutes once it starts."
echo "    Progress: bash ${SHOW_DIR}/cry_status.sh"
echo "    Logs:     ${SHOW_DIR}/logs/cry_subject_${job_id}_<task>.log"
