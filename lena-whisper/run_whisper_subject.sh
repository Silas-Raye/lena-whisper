#!/bin/bash
# run_whisper_subject.sh — one SLURM array task = one participant.
#
# Don't sbatch this file yourself. submit_whisper_subjects.sh submits it and
# supplies the account, partition, GPU, time limit, and log path from config.sh.
#SBATCH --job-name=whisper_subject
#SBATCH --nodes=1
#SBATCH --ntasks=1

LIST="${1:?This script is submitted by submit_whisper_subjects.sh; run that instead.}"

# The job starts in the folder it was submitted from: the repo folder.
# shellcheck source=lib.sh
source "${SLURM_SUBMIT_DIR}/lib.sh"

if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    echo "[X] No Python environment at ${VENV_DIR}. Run: bash ${LW_DIR}/setup.sh"
    exit 1
fi

setup_accre_software_stack
module load "${FFMPEG_MODULE}"
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

# Strict mode only after loading software; those setup scripts aren't
# written for it.
set -euo pipefail

if ! command -v ffmpeg >/dev/null; then
    echo "[X] ffmpeg isn't available. Check FFMPEG_MODULE in config.sh"
    echo "    against: module spider ffmpeg"
    exit 1
fi

SUBJ=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$LIST")

if [ -z "$SUBJ" ]; then
    echo "[X] No participant on line ${SLURM_ARRAY_TASK_ID} of ${LIST}"
    exit 1
fi

echo "=============================="
echo "Starting participant: ${SUBJ}"
echo "Array task:   ${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
echo "Node:         ${SLURMD_NODENAME:-unknown}"
echo "Time limit:   ${SLURM_TIME}"
echo "Start time:   $(date)"
echo "=============================="

export LW_DATA_ROOT="${DATA_ROOT}"
export LW_WHISPER_MODEL="${WHISPER_MODEL}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

# -u writes output immediately, so the log shows progress while the job runs
# and keeps its last lines if SLURM stops the job at the time limit.
python -u "${LW_DIR}/batchWhisper.py" "${SUBJ}"

echo "=============================="
echo "Finished participant: ${SUBJ}"
echo "End time: $(date)"
echo "=============================="
