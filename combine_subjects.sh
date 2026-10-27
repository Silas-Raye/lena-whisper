#!/bin/bash
# combine_subjects.sh — make the combined CSV, and one CSV per source (Whisper,
# cry and TV detection, .its), for each participant in participant_ids.txt
# whose transcription and cry and TV detection are done.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/combine_subjects.sh
#   bash ~/lena-whisper/combine_subjects.sh --overwrite    (redo finished ones)
#
# Runs combineTranscripts.py, which needs a few seconds per recording, so it
# runs here rather than as a job. Participants that aren't ready are listed
# with the reason; run this again once they are. Other options are passed on
# to combineTranscripts.py (python3 combineTranscripts.py --help).

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

overwrite=0
for arg in "$@"; do
    if [ "$arg" = "--overwrite" ]; then
        overwrite=1
    fi
done

if [ ! -f "$LW_IDS_FILE" ] || [ -z "$(clean_ids "$LW_IDS_FILE")" ]; then
    echo "[X] ${SHOW_DIR}/participant_ids.txt has no participant IDs."
    exit 1
fi

# combineTranscripts.py needs Python 3.9 or newer and nothing else.
python=python3
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
    python="${CRY_VENV_DIR}/bin/python"
    if [ ! -x "$python" ]; then
        echo "[X] This needs Python 3.9 or newer. Run setup first: bash ${SHOW_DIR}/setup.sh"
        exit 1
    fi
fi

queued_cry=$(queued_participants cry_subject)

echo "[*] Checking participants in participant_ids.txt..."
ready=()
while IFS= read -r pid; do
    if [ -f "$(combined_path "$pid")" ] && [ "$overwrite" -eq 0 ]; then
        printf "    %-16s already combined\n" "$pid"
        continue
    fi
    read -r state n_done n_chunks <<< "$(participant_status "$pid")"
    case "$state" in
        new|chunking)
            printf "    %-16s waiting for Whisper (not transcribed yet)\n" "$pid"
            continue ;;
        transcribing)
            printf "    %-16s waiting for Whisper (%s/%s chunks)\n" "$pid" "$n_done" "$n_chunks"
            continue ;;
        missing)
            # The recording and chunks may be gone while the transcripts are
            # still here; combineTranscripts.py checks that they're complete.
            if [ ! -d "$(transcript_dir "$pid")" ]; then
                printf "    %-16s no recording or transcripts in %s\n" "$pid" "$DATA_ROOT"
                continue
            fi ;;
    esac
    if ! cry_done "$pid"; then
        if grep -qxF "$pid" <<< "$queued_cry"; then
            printf "    %-16s waiting for cry and TV detection (queued or running)\n" "$pid"
        else
            printf "    %-16s waiting for cry and TV detection (run submit_cry_subjects.sh)\n" "$pid"
        fi
        continue
    fi
    printf "    %-16s ready\n" "$pid"
    ready+=("$pid")
done < <(recording_ids "$LW_IDS_FILE")

if [ "${#ready[@]}" -eq 0 ]; then
    echo "[✓] Nothing to combine right now."
    exit 0
fi

echo
status=0
"$python" "${LW_DIR}/combineTranscripts.py" \
    --data-root "$DATA_ROOT" --its-dir "$ITS_DIR" \
    --lookup "$LOOKUP_TABLE" --timepoint "$TIMEPOINT" "$@" "${ready[@]}" || status=$?

echo
if [ "$status" -eq 0 ]; then
    echo "[✓] Done. To copy the results to the lab server, run:"
    echo "    bash ${SHOW_DIR}/print_results_commands.sh"
else
    echo "[!] Some participants weren't combined; the messages above say why."
    echo "    .its files go in ${ITS_DIR/#"$HOME"/"~"}/ (bash ${SHOW_DIR}/print_its_commands.sh)."
fi
exit "$status"
