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
show() { echo "${1/#"$HOME"/"~"}"; }

# ---- 0. Make sure we're on ACCRE --------------------------------------------
if [ ! -d "$(dirname "$DATA_ROOT")" ] || ! command -v sbatch >/dev/null; then
    echo "[X] Run this on ACCRE, not on your own computer:"
    echo "      ssh <VUNetID>@login.accre.vu"
    echo "      bash ~/lena-whisper/setup.sh"
    exit 1
fi

# ---- 1. SLURM accounts ------------------------------------------------------
step 1 "Check access to the lab's SLURM accounts"
for pair in "${SLURM_ACCOUNT}:GPU account (Whisper)" "${CRY_SLURM_ACCOUNT}:CPU account (cry and TV detection)"; do
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

# ---- 2. Data folders --------------------------------------------------------
step 2 "Create your data folders in /nobackup"
mkdir -p "$RAW_DIR" "$CHUNK_DIR"
# Recordings are research data: only you can read your folder.
chmod 700 "$DATA_ROOT"
for dir in "$RAW_DIR" "$CHUNK_DIR"; do
    echo "    [✓] ${dir}"
done
echo "    Each child's results will go in ${DATA_ROOT}/<ID>_output/."
if mkdir -p "$ITS_DIR" 2>/dev/null; then
    echo "    [✓] ${ITS_DIR}"
else
    echo "    [!] Couldn't create ${ITS_DIR} (ITS_DIR in config.sh). Ask the lab maintainer."
fi
echo "        (Only you can open ${DATA_ROOT}.)"

# ---- 3. Files in this folder ------------------------------------------------
step 3 "Prepare ${SHOW_DIR}"
mkdir -p "${LW_DIR}/logs" "${LW_DIR}/runs"
if [ ! -f "$LW_IDS_FILE" ]; then
    cat > "$LW_IDS_FILE" <<'EOF'
# One participant ID per line, for example 1006. Each ID stands for all of
# that child's recordings at the TIMEPOINT in config.sh. Lines that start
# with # are ignored.
EOF
    echo "    [✓] Created participant_ids.txt"
else
    echo "    [✓] participant_ids.txt already exists; left unchanged"
fi

# ---- 4. Whisper environment -------------------------------------------------
step 4 "Set up the Whisper environment ($(show "$VENV_DIR"))"
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

# ---- 5. Whisper model -------------------------------------------------------
step 5 "Download the Whisper ${WHISPER_MODEL} model (about 3 GB, once)"
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

# ---- 6. Cry and TV detection ------------------------------------------------
step 6 "Set up cry and TV detection with YAMNet ($(show "$CRY_VENV_DIR"))"
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

# ---- 7. Your commands -------------------------------------------------------
step 7 "Write your commands to ${SHOW_DIR}/my_commands.txt"
cat > "${LW_DIR}/my_commands.txt" <<EOF
My commands (${USER})
=====================================================================

Run each step's commands on ACCRE, in order. Steps 2 and 7 print copy
commands with your paths filled in; run those on YOUR computer.


1. List the participant IDs, one per line (for example 1006)

       nano ${SHOW_DIR}/participant_ids.txt


2. Copy the recordings and .its files to ACCRE

       bash ${SHOW_DIR}/print_wav_commands.sh
       bash ${SHOW_DIR}/print_its_commands.sh

   Copy the .its files before step 3: transcription cuts each recording
   into chunks that line up with its .its file's 5-minute blocks, and
   uses plain 5-minute chunks if the .its file isn't there.


3. Start transcribing

       bash ${SHOW_DIR}/submit_whisper_subjects.sh


4. Start cry and TV detection (once status.sh shows "in progress")

       bash ${SHOW_DIR}/submit_cry_subjects.sh


5. Check progress (run step 3 again after each round of jobs)

       bash ${SHOW_DIR}/status.sh
       bash ${SHOW_DIR}/cry_status.sh


6. Combine the results

       bash ${SHOW_DIR}/combine_subjects.sh


7. Copy the results to the lab server

       bash ${SHOW_DIR}/print_results_commands.sh


8. Delete the finished participants' files from ACCRE

       bash ${SHOW_DIR}/cleanup.sh <ID>
EOF
echo "    [✓] Saved. View it with: cat ${SHOW_DIR}/my_commands.txt"

# ---- Done -------------------------------------------------------------------
cat <<EOF

[✓] Setup complete. Next:
    1. List the participant IDs      (nano ${SHOW_DIR}/participant_ids.txt)
    2. Copy recordings and .its      (bash ${SHOW_DIR}/print_wav_commands.sh, print_its_commands.sh)
    3. Start transcribing            (bash ${SHOW_DIR}/submit_whisper_subjects.sh)
    4. Start cry and TV detection    (bash ${SHOW_DIR}/submit_cry_subjects.sh)
    5. Check progress                (bash ${SHOW_DIR}/status.sh, cry_status.sh)
    6. Combine the results           (bash ${SHOW_DIR}/combine_subjects.sh)
    7. Copy results to the server    (bash ${SHOW_DIR}/print_results_commands.sh)
    All of these are in ${SHOW_DIR}/my_commands.txt.
EOF
