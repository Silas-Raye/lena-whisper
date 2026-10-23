# shellcheck shell=bash disable=SC2034
# lib.sh — shared helpers. Other scripts source this file; don't run it directly.

LW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${LW_DIR}/config.sh"

LW_IDS_FILE="${LW_DIR}/participant_ids.txt"

# Print the participant IDs in a list file, one per line, cleaned up so that a
# file edited on Windows or Mac still works: drops a byte-order mark, Windows
# line endings, comments (#), blank lines, surrounding spaces, a trailing .wav,
# and duplicates.
clean_ids() {
    sed -e '1s/^\xEF\xBB\xBF//' \
        -e 's/\r$//' \
        -e 's/#.*//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        -e 's/\.[wW][aA][vV]$//' "$1" \
        | awk 'NF && !seen[$0]++'
}

# Count the arguments that are existing files. An unmatched glob stays a
# literal pattern, which doesn't exist, so it counts as 0.
count_files() {
    local n=0 f
    for f in "$@"; do
        [ -e "$f" ] && n=$((n + 1))
    done
    echo "$n"
}

# Print the path of a participant's raw recording, or nothing if it's missing.
# Looks in rawAudio/<first 4 digits>/ first, then directly in rawAudio/.
raw_path() {
    local pid="$1" candidate
    for candidate in "${RAW_DIR}/${pid:0:4}/${pid}.wav" "${RAW_DIR}/${pid}.wav"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
}

# Print "<state> <chunks transcribed> <total chunks>" for one participant.
# States:
#   missing       no recording on ACCRE
#   new           recording uploaded, not chunked yet
#   chunking      chunking is running, or a job stopped partway through it
#   transcribing  chunked, some chunks not transcribed yet
#   done          every chunk has a transcript
participant_status() {
    local pid="$1"
    local cdir="${CHUNK_DIR}/${pid:0:4}/${pid}"
    local odir="${OUT_DIR}/${pid:0:4}/${pid}"
    local n_chunks n_json
    n_chunks=$(count_files "${cdir}/${pid}_audiochunk_"*.wav)
    n_json=$(count_files "${odir}/${pid}_audiochunk_"*.json)

    if [ -e "${cdir}/${pid}_temp.wav" ]; then
        echo "chunking ${n_json} ${n_chunks}"
    elif [ "$n_chunks" -gt 0 ] && [ "$n_json" -ge "$n_chunks" ]; then
        echo "done ${n_json} ${n_chunks}"
    elif [ "$n_chunks" -gt 0 ]; then
        echo "transcribing ${n_json} ${n_chunks}"
    elif [ -n "$(raw_path "$pid")" ]; then
        echo "new 0 0"
    else
        echo "missing 0 0"
    fi
}
