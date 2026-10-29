#!/bin/bash
# copy_results_to_lab_server.sh — print the commands that copy the results of
# the participants in participant_ids.txt from ACCRE to the lab server.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/copy_results_to_lab_server.sh
#
# Then paste the commands into a terminal on YOUR computer, connected to the
# VPN and the lab server. For each child they copy everything in <ID>_output
# on ACCRE into the lab server's SERVER_TXT/<ID>/ folder (config.sh).

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
mac_txt="${SERVER_MAC}/${SERVER_TXT}"

# The children with at least one combined recording, by output folder.
odirs=()
while IFS= read -r pid; do
    if [ -f "$(combined_path "$pid")" ]; then
        odirs+=("$(output_dir "$pid")")
    else
        echo "[!] ${pid}: not combined yet (combine_subjects.sh); skipping" >&2
    fi
done < <(recording_ids "$LW_IDS_FILE")
mapfile -t odirs < <(printf '%s\n' "${odirs[@]+"${odirs[@]}"}" | awk 'NF && !seen[$0]++')

if [ "${#odirs[@]}" -eq 0 ]; then
    echo "[X] No recording in participant_ids.txt is combined yet."
    exit 1
fi

cat <<EOT

Copy results to the lab server (${TIMEPOINT})
=====================================================================

Run these on YOUR computer, not on ACCRE. Connect to the VPN and the
lab server first. Each scp asks for your VUNetID password.


WINDOWS (Command Prompt; the lab server mapped to ${SERVER_WIN})
---------------------------------------------------------------------

EOT
for odir in "${odirs[@]}"; do
    id=$(basename "$odir" _output)
    echo "mkdir \"${win_txt_mkdir}\\${id}\" 2>nul"
    echo "scp -r \"${host}:${odir}/*\" \"${win_txt}/${id}/\""
    echo
done

cat <<EOT

MAC (Terminal)
---------------------------------------------------------------------

EOT
for odir in "${odirs[@]}"; do
    id=$(basename "$odir" _output)
    echo "mkdir -p \"${mac_txt}/${id}\""
    echo "scp -r \"${host}:${odir}/*\" \"${mac_txt}/${id}/\""
    echo
done
