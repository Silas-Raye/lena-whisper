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

# Print the recording IDs that a participant list stands for, one per line.
# A line like 1006 means each of that child's recordings on ACCRE
# (1006_029792, 1006_029795, ...), found from their recordings, chunks, or
# transcripts. A full recording ID like 1006_029795 means just that one. An ID
# with no files on ACCRE is printed as is, so the scripts report it missing.
recording_ids() {
    local id found
    clean_ids "$1" | while IFS= read -r id; do
        if [[ "$id" == *_* ]]; then
            echo "$id"
            continue
        fi
        found=$(for f in "${RAW_DIR}/${id:0:4}/${id}"_*.wav "${RAW_DIR}/${id}"_*.wav \
                         "${CHUNK_DIR}/${id:0:4}/${id}"_* "$(output_dir "$id")/transcriptOut/${id}"_*; do
                    if [ -e "$f" ]; then basename "$f" .wav; fi
                done | sort -u)
        echo "${found:-$id}"
    done | awk '!seen[$0]++'
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

# Print where a participant's output goes. Each child has one folder,
# DATA_ROOT/<ID>_output, named for the part of the ID before the "_"
# (1006_output for 1006_029795).
output_dir()     { echo "${DATA_ROOT}/${1%%_*}_output"; }
transcript_dir() { echo "$(output_dir "$1")/transcriptOut/${1}"; }
cry_path()       { echo "$(output_dir "$1")/cryOut/${1}_cry.csv"; }
combined_path()  { echo "$(output_dir "$1")/combinedOut/${1}_combined.csv"; }

# Succeed if a participant's cry CSV exists and has the TV columns, which
# CSVs from before TV detection was added don't have.
cry_done() {
    [ -f "$(cry_path "$1")" ] && head -n 1 "$(cry_path "$1")" | grep -q ',tv,'
}

# Print the cry and TV detection state of one participant. It reads the
# chunks that the first Whisper job cuts from the recording.
#   missing   no recording or chunks on ACCRE
#   waiting   recording uploaded, not chunked yet
#   ready     chunked, cry and TV detection not run yet
#   old       the cry CSV is from before TV detection; run it again
#   done      the cry CSV exists, with TV
cry_state() {
    local state
    if cry_done "$1"; then
        echo "done"
        return
    fi
    if [ -f "$(cry_path "$1")" ]; then
        echo "old"
        return
    fi
    read -r state _ <<< "$(participant_status "$1")"
    case "$state" in
        transcribing|done) echo "ready" ;;
        new|chunking)      echo "waiting" ;;
        *)                 echo "missing" ;;
    esac
}

# Print the participant of each of your queued or running jobs with the given
# names (comma-separated), one per line. A job's participant is the line of
# its participant list that matches its array task number. The list is in the
# job's comment (submit_cry_subjects.sh puts it there) or, failing that, in
# its command line; "?" means it couldn't be found.
queued_participants() {
    local job comment task list
    { squeue --me -h -r -n "$1" -o "%i %k" 2>/dev/null || true; } | while read -r job comment; do
        task="${job##*_}"
        list="$comment"
        if [ ! -f "$list" ]; then
            list=$(scontrol show job "$job" 2>/dev/null | sed -n 's/^ *Command=[^ ]* //p')
        fi
        if [[ "$task" =~ ^[0-9]+$ ]] && [ -f "$list" ]; then
            sed -n "${task}p" "$list"
        else
            echo "?"
        fi
    done
}

# Print the lookup table's .its file names for a child at TIMEPOINT, one per
# line: the rows whose ExternalReferenceID is <ID4>_<age> (1006_6mo, also
# 1006_6mo_Pilot). With a full recording ID, only that recorder's files.
its_names() {
    local id4="${1%%_*}" recorder="" age="${TIMEPOINT//-/}"
    [[ "$1" == *_* ]] && recorder="${1#*_}"
    sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$LOOKUP_TABLE" \
        | awk -F, -v ref="${id4}_${age}" -v rec="$recorder" '
            NR > 1 && ($1 == ref || index($1, ref "_") == 1) && $3 != "" {
                name = $3; sub(/\.its$/, "", name)
                if (rec == "" || name ~ ("_" rec "$")) print name
            }'
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
    local odir
    odir=$(transcript_dir "$pid")
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
