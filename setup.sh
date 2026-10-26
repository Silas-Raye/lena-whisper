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

step() { printf "\n[%s/8] %s\n" "$1" "$2"; }
show() { echo "${1/#"$HOME"/"~"}"; }

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

# ---- 2. SLURM accounts ------------------------------------------------------
step 2 "Check access to the lab's SLURM accounts"
for pair in "${SLURM_ACCOUNT}:GPU account (Whisper)" "${CRY_SLURM_ACCOUNT}:CPU account (cry detection)"; do
    account="${pair%%:*}"
    purpose="${pair#*:}"
    [ -n "$account" ] || continue
    account_found=$(sacctmgr -n -P show assoc where user="$USER" \
        account="$account" format=Account 2>/dev/null || true)
    if [ -n "$account_found" ]; then
        echo "    [✓] You can submit jobs to ${account}, the ${purpose}"
    else
        echo "    [!] Your user isn't in ${account}, the ${purpose}, so those jobs"
        echo "        will fail with \"Invalid account\". Ask the lab to have ACCRE add"
        echo "        you. Setup continues; you don't need to rerun it after you're added."
    fi
done

# ---- 3. Data folders --------------------------------------------------------
step 3 "Create your data folders in /nobackup"
mkdir -p "$RAW_DIR" "$CHUNK_DIR" "$OUT_DIR" "$CRY_DIR" "$COMBINED_DIR"
# Recordings are research data: only you can read your folder.
chmod 700 "$DATA_ROOT"
for dir in "$RAW_DIR" "$CHUNK_DIR" "$OUT_DIR" "$CRY_DIR" "$COMBINED_DIR"; do
    echo "    [✓] ${dir}"
done
if mkdir -p "$ITS_DIR" 2>/dev/null; then
    echo "    [✓] ${ITS_DIR}"
else
    echo "    [!] Couldn't create ${ITS_DIR} (ITS_DIR in config.sh). Ask the lab maintainer."
fi
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

# ---- 5. Whisper environment -------------------------------------------------
step 5 "Set up the Whisper environment ($(show "$VENV_DIR"))"
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

# Both environments unpack their install files in /nobackup: the gateway
# limits /tmp to 2 GB per user, and PyTorch's and TensorFlow's are larger.
pip_tmp="${DATA_ROOT}/.pip-tmp"

if [ -d "${HOME}/whisper-env" ] && [ "${HOME}/whisper-env" != "$VENV_DIR" ]; then
    echo "    [~] ~/whisper-env is from an older setup. The environment now lives in"
    echo "        $(show "$VENV_DIR"). When setup finishes, cleanup.sh can delete the old one."
fi
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
set +u
deactivate
set -u

# ---- 7. Cry detection -------------------------------------------------------
step 7 "Set up cry detection with YAMNet ($(show "$CRY_VENV_DIR"))"
if [ ! -f "${CRY_VENV_DIR}/bin/activate" ]; then
    echo "    Creating the environment..."
    python3 -m venv "$CRY_VENV_DIR"
fi
set +u
# shellcheck source=/dev/null
source "${CRY_VENV_DIR}/bin/activate"
set -u

if python -c "import tensorflow, soundfile" 2>/dev/null; then
    echo "    [✓] TensorFlow is already installed"
else
    echo "    Installing TensorFlow. It takes about 1 GB of space and can take"
    echo "    5 minutes..."
    mkdir -p "$pip_tmp"
    TMPDIR="$pip_tmp" pip install --no-cache-dir --upgrade pip
    if TMPDIR="$pip_tmp" pip install --no-cache-dir -r "${LW_DIR}/requirements-cry.txt"; then
        echo "    [✓] TensorFlow installed"
    else
        echo "    [!] TensorFlow didn't install (see pip's message above), so cry"
        echo "        detection can't run yet. To see which TensorFlow versions ACCRE"
        echo "        offers, run: avail_wheels \"tensorflow*\""
        echo "        Setup continues; run it again after fixing requirements-cry.txt."
    fi
    rm -rf "$pip_tmp"
fi

# YAMNet comes with the repository (cry_model/yamnet); check that it loads.
if python -c "import tensorflow" 2>/dev/null \
        && ! python "${LW_DIR}/batchCryDetection.py" --check 2>&1 | sed 's/^/    /'; then
    echo "    [!] YAMNet didn't load; see the message above."
fi
set +u
deactivate
set -u

# ---- 8. Personalized copy commands ------------------------------------------
step 8 "Write your copy commands to ${SHOW_DIR}/my_commands.txt"
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
  <ITS_FOLDER>   the lab server folder with the .its files and lookup table
  <ITS_FILE>     an .its file's name, for example 20211105_123641_029768

---------------------------------------------------------------------
MAC (Terminal)
---------------------------------------------------------------------
Upload a recording to ACCRE:
  scp "${mac_raw}/<PARTICIPANT>.wav" ${host}:${RAW_DIR}/

Upload your participant list (from the folder that contains it):
  scp participant_ids.txt ${host}:${remote_repo}/participant_ids.txt

Upload .its files and the lookup table:
  scp "<ITS_FOLDER>/<ITS_FILE>.its" "<ITS_FOLDER>/its_identifier_file_babies_crb.csv" ${host}:${ITS_DIR}/

Copy one participant's transcripts, combined CSV, and cry detection CSV
to the lab server:
  mkdir -p "${mac_txt}"
  scp -r ${host}:${OUT_DIR}/<ID4>/<PARTICIPANT> "${mac_txt}/"
  scp ${host}:${COMBINED_DIR}/<ID4>/<PARTICIPANT>_combined.csv "${mac_txt}/"
  scp ${host}:${CRY_DIR}/<ID4>/<PARTICIPANT>_cry.csv "${mac_txt}/"

---------------------------------------------------------------------
WINDOWS (Command Prompt; X: is the drive you mapped the lab server to)
---------------------------------------------------------------------
Upload a recording to ACCRE:
  scp "${win_raw}/<PARTICIPANT>.wav" ${host}:${RAW_DIR}/

Upload your participant list (from the folder that contains it):
  scp participant_ids.txt ${host}:${remote_repo}/participant_ids.txt

Upload .its files and the lookup table:
  scp "<ITS_FOLDER>/<ITS_FILE>.its" "<ITS_FOLDER>/its_identifier_file_babies_crb.csv" ${host}:${ITS_DIR}/

Copy one participant's transcripts, combined CSV, and cry detection CSV
to the lab server (ignore mkdir's message if the folder already exists):
  mkdir "${win_txt_mkdir}"
  scp -r ${host}:${OUT_DIR}/<ID4>/<PARTICIPANT> "${win_txt}/"
  scp ${host}:${COMBINED_DIR}/<ID4>/<PARTICIPANT>_combined.csv "${win_txt}/"
  scp ${host}:${CRY_DIR}/<ID4>/<PARTICIPANT>_cry.csv "${win_txt}/"
EOF
echo "    [✓] Saved. View it with: cat ${SHOW_DIR}/my_commands.txt"

# ---- Done -------------------------------------------------------------------
cat <<EOF

[✓] Setup complete. Next:
    1. Copy recordings to ACCRE      (cat ${SHOW_DIR}/my_commands.txt)
    2. List their IDs                (nano ${SHOW_DIR}/participant_ids.txt)
    3. Start transcribing            (bash ${SHOW_DIR}/submit_whisper_subjects.sh)
    4. Start cry detection           (bash ${SHOW_DIR}/submit_cry_subjects.sh)
    5. Check progress                (bash ${SHOW_DIR}/status.sh, cry_status.sh)
    6. Combine the results           (bash ${SHOW_DIR}/combine_subjects.sh)
EOF
