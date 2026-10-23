#!/bin/bash
# setup.sh — one-time setup for the LENA Whisper pipeline on ACCRE.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/setup.sh
#
# Safe to run again: each step skips work that's already done.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

step() { printf "\n[%s/7] %s\n" "$1" "$2"; }

# ---- 0. Make sure we're on ACCRE --------------------------------------------
if [ ! -d "$(dirname "$DATA_ROOT")" ] || ! command -v sbatch >/dev/null; then
    echo "[X] Run this on ACCRE, not on your own computer:"
    echo "      ssh <VUNetID>@login.accre.vu"
    echo "      bash ~/lena-whisper/setup.sh"
    exit 1
fi

# ---- 1. VUNetID -------------------------------------------------------------
step 1 "Confirm your VUNetID"
echo "    You're logged in to ACCRE as: ${USER}"
echo "    Your files will go in:        ${DATA_ROOT}"
read -r -p "    Is ${USER} your VUNetID? [Y/n] " answer || answer=""
if [[ ! "${answer:-Y}" =~ ^[Yy] ]]; then
    echo "[X] Log out, log back in with your own VUNetID, and run setup again:"
    echo "      ssh <VUNetID>@login.accre.vu"
    exit 1
fi

# ---- 2. SLURM account -------------------------------------------------------
step 2 "Check access to the lab's GPU account (${SLURM_ACCOUNT})"
account_found=$(sacctmgr -n -P show assoc where user="$USER" \
    account="$SLURM_ACCOUNT" format=Account 2>/dev/null || true)
if [ -n "$account_found" ]; then
    echo "    [✓] You can submit jobs to ${SLURM_ACCOUNT}"
else
    echo "    [!] Your user isn't in ${SLURM_ACCOUNT} yet, so jobs will fail with"
    echo "        \"Invalid account\". Ask the lab to have ACCRE add you. Setup"
    echo "        continues; you don't need to rerun it after you're added."
fi

# ---- 3. Data folders --------------------------------------------------------
step 3 "Create your data folders in /nobackup"
mkdir -p "$RAW_DIR" "$CHUNK_DIR" "$OUT_DIR"
# Recordings are research data: only you can read your folder.
chmod 700 "$DATA_ROOT"
echo "    [✓] ${RAW_DIR}"
echo "    [✓] ${CHUNK_DIR}"
echo "    [✓] ${OUT_DIR}"
echo "        (Only you can open ${DATA_ROOT}.)"

# ---- 4. Files in this folder ------------------------------------------------
step 4 "Prepare ${SHOW_DIR}"
mkdir -p "${LW_DIR}/logs" "${LW_DIR}/runs"
if [ ! -f "$LW_IDS_FILE" ]; then
    cat > "$LW_IDS_FILE" <<'EOF'
# One participant ID per line: the recording's file name without .wav.
# Lines that start with # are ignored. Example:
# 1243_029768
EOF
    echo "    [✓] Created participant_ids.txt"
else
    echo "    [✓] participant_ids.txt already exists; left unchanged"
fi

# ---- 5. Python environment --------------------------------------------------
step 5 "Set up the Python environment (${VENV_DIR/#"$HOME"/"~"})"
set +eu   # ACCRE's environment scripts aren't written for strict mode
if ! type setup_accre_software_stack >/dev/null 2>&1; then
    source /etc/profile >/dev/null 2>&1
fi
if ! type setup_accre_software_stack >/dev/null 2>&1; then
    echo "[X] ACCRE's setup_accre_software_stack command isn't available."
    echo "    Log out, log back in, and run setup again."
    exit 1
fi
setup_accre_software_stack
set -eu

if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    echo "    Creating the environment..."
    python3 -m venv "$VENV_DIR"
fi
set +u
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"
set -u

if python -c "import whisper" 2>/dev/null; then
    echo "    [✓] Whisper is already installed"
else
    echo "    Installing Whisper and PyTorch. This downloads several GB and can"
    echo "    take 10-20 minutes..."
    # The gateway limits /tmp to 2 GB per user, and PyTorch's install files
    # are larger, so unpack them in /nobackup instead and skip pip's cache.
    pip_tmp="${DATA_ROOT}/.pip-tmp"
    mkdir -p "$pip_tmp"
    TMPDIR="$pip_tmp" pip install --no-cache-dir --upgrade pip
    TMPDIR="$pip_tmp" pip install --no-cache-dir openai-whisper
    rm -rf "$pip_tmp"
    echo "    [✓] Whisper installed"
fi

# ---- 6. Whisper model -------------------------------------------------------
step 6 "Download the Whisper ${WHISPER_MODEL} model (about 3 GB, once)"
# Downloading now keeps the first job from spending its GPU time on it.
# Whisper checks the file and skips the download when it's already complete.
if python - "$WHISPER_MODEL" <<'EOF'
import os, sys, whisper
name = sys.argv[1]
root = os.path.join(os.getenv("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "whisper")
whisper._download(whisper._MODELS[name], root, False)
print(f"    [✓] Model ready in {root}")
EOF
then
    :
else
    echo "    [!] The download didn't finish. The first job will download the"
    echo "        model instead, using a few minutes of its GPU time."
fi

# ---- 7. Personalized copy commands ------------------------------------------
step 7 "Write your copy commands to ${SHOW_DIR}/my_commands.txt"
if [[ "$LW_DIR" == "$HOME"/* ]]; then
    remote_repo="${LW_DIR#"$HOME"/}"   # scp paths without a leading / start in your home folder
else
    remote_repo="$LW_DIR"
fi
host="${USER}@login.accre.vu"
mac_raw="/Volumes/HumphreysLab/Daily_2/LENA/LENA_raw/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_Raw/<ID4>"
mac_txt="/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>"
win_raw='X:/Daily_2/LENA/LENA_raw/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_Raw/<ID4>'
win_txt='X:/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>'
win_txt_mkdir="${win_txt//\//\\}"   # cmd's mkdir needs backslashes

cat > "${LW_DIR}/my_commands.txt" <<EOF
Copy commands for ${USER}
=====================================================================
Run these on YOUR computer, not on ACCRE. Connect to the VPN and the
lab server first. Then replace:
  <TIMEPOINT>    the age folder, for example 12-mo
  <ID4>          the first 4 digits of the ID, for example 1243
  <PARTICIPANT>  the full ID, for example 1243_029768

---------------------------------------------------------------------
MAC (Terminal)
---------------------------------------------------------------------
Upload a recording to ACCRE:
  scp "${mac_raw}/<PARTICIPANT>.wav" ${host}:${RAW_DIR}/

Upload your participant list (from the folder that contains it):
  scp participant_ids.txt ${host}:${remote_repo}/participant_ids.txt

Copy one participant's finished transcripts to the lab server:
  mkdir -p "${mac_txt}"
  scp -r ${host}:${OUT_DIR}/<ID4>/<PARTICIPANT> "${mac_txt}/"

---------------------------------------------------------------------
WINDOWS (Command Prompt; X: is the drive you mapped the lab server to)
---------------------------------------------------------------------
Upload a recording to ACCRE:
  scp "${win_raw}/<PARTICIPANT>.wav" ${host}:${RAW_DIR}/

Upload your participant list (from the folder that contains it):
  scp participant_ids.txt ${host}:${remote_repo}/participant_ids.txt

Copy one participant's finished transcripts to the lab server
(ignore mkdir's message if the folder already exists):
  mkdir "${win_txt_mkdir}"
  scp -r ${host}:${OUT_DIR}/<ID4>/<PARTICIPANT> "${win_txt}/"
EOF
echo "    [✓] Saved. View it with: cat ${SHOW_DIR}/my_commands.txt"

# ---- Done -------------------------------------------------------------------
cat <<EOF

[✓] Setup complete. Next:
    1. Copy recordings to ACCRE      (cat ${SHOW_DIR}/my_commands.txt)
    2. List their IDs                (nano ${SHOW_DIR}/participant_ids.txt)
    3. Start transcribing            (bash ${SHOW_DIR}/submit_whisper_subjects.sh)
    4. Check progress                (bash ${SHOW_DIR}/status.sh)
EOF
