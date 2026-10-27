#!/bin/bash
# print_results_commands.sh — print the commands that copy the results of the
# participants in participant_ids.txt from ACCRE to the lab server.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/print_results_commands.sh
#
# Then paste the commands into a terminal on YOUR computer, connected to the
# VPN and the lab server. For each recording they copy its Whisper JSON
# folder and its CSVs from <ID>_output on ACCRE into the lab server's
# <TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/ folder.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    exit 1
fi

host="${USER}@login.accre.vu"
win_txt="${SERVER_WIN}/${SERVER_TXT}"
win_txt_mkdir="${win_txt//\//\\}"   # cmd's mkdir needs backslashes

# The recordings that have a combined CSV.
pids=()
while IFS= read -r pid; do
    if [ -f "$(combined_path "$pid")" ]; then
        pids+=("$pid")
    else
        echo "[!] ${pid}: not combined yet (combine_subjects.sh); skipping" >&2
    fi
done < <(recording_ids "$LW_IDS_FILE")

if [ "${#pids[@]}" -eq 0 ]; then
    echo "[X] No recording in participant_ids.txt is combined yet."
    exit 1
fi

cat <<EOF

Copy results to the lab server (${TIMEPOINT})
=====================================================================

Run these on YOUR computer, not on ACCRE. Connect to the VPN and the
lab server first. Each scp asks for your VUNetID password.


WINDOWS (Command Prompt; the lab server mapped to ${SERVER_WIN})
---------------------------------------------------------------------

EOF
for pid in "${pids[@]}"; do
    id4="${pid:0:4}"
    echo "mkdir \"${win_txt_mkdir}\\${id4}\" 2>nul"
    echo "scp -r ${host}:$(transcript_dir "$pid") \"${win_txt}/${id4}/\""
    echo "scp \"${host}:$(output_dir "$pid")/combinedOut/${pid}_*.csv\" \"${win_txt}/${id4}/\""
    echo
done

cat <<EOF

MAC (Terminal)
---------------------------------------------------------------------

EOF
for pid in "${pids[@]}"; do
    id4="${pid:0:4}"
    echo "mkdir -p \"${SERVER_MAC}/${SERVER_TXT}/${id4}\""
    echo "scp -r ${host}:$(transcript_dir "$pid") \"${SERVER_MAC}/${SERVER_TXT}/${id4}/\""
    echo "scp \"${host}:$(output_dir "$pid")/combinedOut/${pid}_*.csv\" \"${SERVER_MAC}/${SERVER_TXT}/${id4}/\""
    echo
done
