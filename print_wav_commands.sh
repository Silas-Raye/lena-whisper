#!/bin/bash
# print_wav_commands.sh — print the commands that copy the recordings of the
# participants in participant_ids.txt from the lab server to ACCRE.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/print_wav_commands.sh
#
# Then paste the commands into a terminal on YOUR computer, connected to the
# VPN and the lab server. For each ID like 1006, they copy every .wav file in
# the lab server's <TIMEPOINT>_BABIES_LENA_Raw/1006/ folder; for a full ID
# like 1006_029795, only 1006_029795.wav. TIMEPOINT is set in config.sh.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    echo "    Add one ID per line (for example 1006): nano ${SHOW_DIR}/participant_ids.txt"
    exit 1
fi

dest="${USER}@login.accre.vu:${RAW_DIR}/"
win_raw="${SERVER_WIN}\\${SERVER_RAW//\//\\}"

# Print "<ID4 folder> <file pattern>" for each line of the list.
wav_patterns() {
    local id
    clean_ids "$LW_IDS_FILE" | while IFS= read -r id; do
        if [[ "$id" == *_* ]]; then
            echo "${id%%_*} ${id}.wav"
        else
            echo "${id} *.wav"
        fi
    done
}

cat <<EOF

Copy recordings to ACCRE (${TIMEPOINT})
=====================================================================

Run these on YOUR computer, not on ACCRE. Connect to the VPN and the
lab server first. Each scp asks for your VUNetID password.


WINDOWS (Command Prompt; the lab server mapped to ${SERVER_WIN})
---------------------------------------------------------------------

EOF
while read -r folder pattern; do
    echo "for %i in (\"${win_raw}\\${folder}\\${pattern}\") do scp \"%i\" ${dest}"
    echo
done < <(wav_patterns)

cat <<EOF

MAC (Terminal)
---------------------------------------------------------------------

EOF
while read -r folder pattern; do
    if [ "$pattern" = "*.wav" ]; then
        echo "scp \"${SERVER_MAC}/${SERVER_RAW}/${folder}/\"*.wav ${dest}"
    else
        echo "scp \"${SERVER_MAC}/${SERVER_RAW}/${folder}/${pattern}\" ${dest}"
    fi
    echo
done < <(wav_patterns)
