# shellcheck shell=bash disable=SC2034
# config.sh — lab-wide settings for the LENA Whisper pipeline.
#
# Every user shares these values, so nobody edits them to get started.
# Per-user paths come from $USER, which on ACCRE is your VUNetID.
# A lab maintainer changes this file when the lab's setup changes.

# ---- Where each user's audio and transcripts live ------------------------
# /nobackup is large, fast, and NOT backed up. Originals stay on the lab server.
DATA_ROOT="${LW_DATA_ROOT:-/nobackup/userspace/${USER}}"
RAW_DIR="${DATA_ROOT}/rawAudio"
CHUNK_DIR="${DATA_ROOT}/chunkedAudioInput"
OUT_DIR="${DATA_ROOT}/transcriptOut"

# ---- Software ---------------------------------------------------------------
VENV_DIR="${HOME}/whisper-env"
FFMPEG_MODULE="ffmpeg/7.1.1"
WHISPER_MODEL="large-v2"

# ---- GPU job settings ---------------------------------------------------------
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
