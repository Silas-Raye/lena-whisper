#!/bin/bash
# print_its_commands.sh — print the commands that copy the .its files of the
# participants in participant_ids.txt from the lab server to ACCRE.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/print_its_commands.sh
#
# Then paste the commands into a terminal on YOUR computer, connected to the
# VPN and the lab server. The lookup table in this folder
# (its_identifier_file_babies_crb.csv) names each child's .its files: the rows
# whose ExternalReferenceID is <ID>_<age>, for example 1006_6mo for TIMEPOINT
# 6-mo in config.sh. The commands search the lab server's
# ITS_files/individual_exports/unzipped_files folder,
# including its subfolders, for those files.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    echo "    Add one ID per line (for example 1006): nano ${SHOW_DIR}/participant_ids.txt"
    exit 1
fi
if [ ! -f "$LOOKUP_TABLE" ]; then
    echo "[X] The lookup table isn't in the repository: ${LOOKUP_TABLE/#"$HOME"/"~"}"
    exit 1
fi

dest="${USER}@login.accre.vu:${ITS_DIR}/"
win_its="${SERVER_WIN}\\${SERVER_ITS//\//\\}"

# Each ID with its .its file names, as "<ID> <name> <name> ...".
lines=()
while IFS= read -r id; do
    names=$(its_names "$id" | tr '\n' ' ')
    if [ -z "$names" ]; then
        echo "[!] ${id}: no row for ${id%%_*}_${TIMEPOINT//-/} in the lookup table; skipping" >&2
        continue
    fi
    lines+=("${id} ${names}")
done < <(clean_ids "$LW_IDS_FILE")

if [ "${#lines[@]}" -eq 0 ]; then
    echo "[X] None of the IDs are in the lookup table for ${TIMEPOINT}."
    exit 1
fi

cat <<EOF

Copy .its files to ACCRE (${TIMEPOINT})
=====================================================================

Run these on YOUR computer, not on ACCRE. Connect to the VPN and the
lab server first. Each scp asks for your VUNetID password.


WINDOWS (Command Prompt; the lab server mapped to ${SERVER_WIN})
---------------------------------------------------------------------

EOF
for line in "${lines[@]}"; do
    read -r -a names <<< "${line#* }"
    files=""
    for name in "${names[@]}"; do
        files+=" \"${win_its}\\${name}.its\""
    done
    echo "for /f \"delims=\" %i in ('dir /s /b${files} 2^>nul') do scp \"%i\" ${dest}"
    echo
done

cat <<EOF

MAC (Terminal)
---------------------------------------------------------------------

EOF
for line in "${lines[@]}"; do
    read -r -a names <<< "${line#* }"
    match=""
    for name in "${names[@]}"; do
        match+="${match:+ -o }-name \"${name}.its\""
    done
    echo "find \"${SERVER_MAC}/${SERVER_ITS}\" \\( ${match} \\) -exec scp {} ${dest} \\;"
    echo
done
