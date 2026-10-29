# shellcheck shell=bash disable=SC2034
# config.sh — lab-wide settings for the LENA Whisper pipeline.
#
# Every user shares these values, so nobody edits them to get started.
# Per-user paths come from $USER, which on ACCRE is your VUNetID.
# A lab maintainer changes this file when the lab's setup changes.

# ---- Where each user's audio and results live ------------------------------
# /nobackup is large, fast, and NOT backed up. Originals stay on the lab server.
DATA_ROOT="${LW_DATA_ROOT:-/nobackup/userspace/${USER}}"
RAW_DIR="${DATA_ROOT}/rawAudio"
CHUNK_DIR="${DATA_ROOT}/chunkedAudioInput"
# Each child's output goes in its own folder, DATA_ROOT/<ID>_output (for
# example 1006_output), with transcriptOut, cryOut, and combinedOut inside.
# lib.sh's output_dir and the Python scripts build these paths.
# .its files from LENA. Only you can open DATA_ROOT, so to share one folder of
# .its files across the lab, point this at a folder that everyone can read.
ITS_DIR="${LW_ITS_DIR:-${DATA_ROOT}/itsFiles}"
# The lookup table that names each .its file's recording. It's kept in the
# repository; replace it with a newer export from the lab server when needed.
LOOKUP_TABLE="${LW_DIR}/its_identifier_file_babies_crb.csv"

# ---- The lab server ----------------------------------------------------------
# The age the lab is processing now. It picks the lab server folders
# (6-mo_BABIES_LENA_Raw) and the lookup table rows (1006_6mo).
TIMEPOINT="6-mo"
# Where the lab server is mounted on each kind of computer, and its folders.
# The print_*_commands.sh scripts and copy_results_to_lab_server.sh put these
# into the copy commands they print. Each child's results go in SERVER_TXT/<ID>/.
SERVER_WIN="X:"
SERVER_MAC="/Volumes/HumphreysLab"
SERVER_RAW="Daily_2/LENA/LENA_raw/BABIES_CRB/${TIMEPOINT}_BABIES_LENA_Raw"
SERVER_ITS="Daily_2/LENA/LENA_raw/BABIES_CRB/ITS_files/individual_exports/unzipped_files"
SERVER_TXT="Daily_2/LENA/LENA_transcripts_5min/BABIES_CRB/${TIMEPOINT}_BABIES_LENA_transcripts"

# ---- Software ---------------------------------------------------------------
# Both Python environments live in the repository folder (LW_DIR, set by lib.sh).
VENV_DIR="${LW_DIR}/whisper-env"
FFMPEG_MODULE="ffmpeg/7.1.1"
WHISPER_MODEL="large-v2"
CRY_VENV_DIR="${LW_DIR}/cry-env"
# YAMNet, which comes with the repository (cry_model/README.md).
CRY_MODEL="${LW_DIR}/cry_model/yamnet"
# A second counts as crying when YAMNet's "Baby cry, infant cry" score is at
# least CRY_THRESHOLD, and as TV when its "Television" or "Radio" score is at
# least TV_THRESHOLD. The CSVs keep every second's scores, so you can apply
# other thresholds later without rerunning.
CRY_THRESHOLD="0.5"
TV_THRESHOLD="0.5"

# ---- GPU job settings (Whisper) ----------------------------------------------
# The lab currently has GPU access only through the shared debug QoS:
# 1 GPU per user and 30 minutes per job. Each job transcribes part of a
# recording; resubmitting continues where the last job stopped.
#
# When the lab gets a batch_gpu account, change these lines to:
#   SLURM_ACCOUNT="l3_humphreys_lab_acc"
#   SLURM_PARTITION="batch_gpu"
#   SLURM_QOS=""                        (leave empty)
#   SLURM_GRES="gpu:<type>:1"           (type from slurm_resources)
#   SLURM_TIME="08:00:00"               (one full recording per job)
SLURM_ACCOUNT="l3_humphreys_lab_iacc"
SLURM_PARTITION="interactive_gpu"
SLURM_QOS="debug_iacc"
SLURM_GRES="gpu:nvidia_rtx_a4000:1"
SLURM_TIME="00:30:00"
SLURM_CPUS="2"
SLURM_MEM="16G"
MAX_PARALLEL="10"   # most array tasks running at once

# ---- CPU job settings (cry and TV detection) ---------------------------------
# Cry and TV detection doesn't need a GPU, so it runs on the regular CPU partition
# with the lab's CPU account (the GPU account's name without _iacc) and
# doesn't compete with Whisper for your one debug GPU. A 16-hour recording
# took about 2 minutes with 2 CPUs and under 2 GB of memory in testing.
CRY_SLURM_ACCOUNT="l3_humphreys_lab"
CRY_SLURM_PARTITION="batch"
CRY_SLURM_TIME="01:00:00"
CRY_SLURM_CPUS="2"
CRY_SLURM_MEM="4G"
