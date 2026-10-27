#!/bin/bash
# run_cry_subject.sh — one SLURM array task = cry and TV detection for one participant.
#
# Don't sbatch this file yourself. submit_cry_subjects.sh submits it and
# supplies the account, partition, time limit, and log path from config.sh.
#SBATCH --job-name=cry_subject
#SBATCH --nodes=1
#SBATCH --ntasks=1

LIST="${1:?This script is submitted by submit_cry_subjects.sh; run that instead.}"

# The job starts in the folder it was submitted from: the repo folder.
# shellcheck source=lib.sh
source "${SLURM_SUBMIT_DIR}/lib.sh"

if [ ! -f "${CRY_VENV_DIR}/bin/activate" ]; then
    echo "[X] No Python environment at ${CRY_VENV_DIR}. Run: bash ${LW_DIR}/setup.sh"
    exit 1
fi

setup_accre_software_stack
# shellcheck source=/dev/null
source "${CRY_VENV_DIR}/bin/activate"

# Strict mode only after loading software; those setup scripts aren't
# written for it.
set -euo pipefail

SUBJ=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$LIST")

if [ -z "$SUBJ" ]; then
    echo "[X] No participant on line ${SLURM_ARRAY_TASK_ID} of ${LIST}"
    exit 1
fi

echo "=============================="
echo "Starting cry and TV detection: ${SUBJ}"
echo "Array task:   ${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
echo "Node:         ${SLURMD_NODENAME:-unknown}"
echo "Time limit:   ${CRY_SLURM_TIME}"
echo "Start time:   $(date)"
echo "=============================="

export LW_DATA_ROOT="${DATA_ROOT}"
export LW_CRY_MODEL="${CRY_MODEL}"
export LW_CRY_THRESHOLD="${CRY_THRESHOLD}"
export LW_TV_THRESHOLD="${TV_THRESHOLD}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

# -u writes output immediately, so the log shows progress while the job runs.
python -u "${LW_DIR}/batchCryDetection.py" "${SUBJ}"

echo "=============================="
echo "Finished cry and TV detection: ${SUBJ}"
echo "End time: $(date)"
echo "=============================="
