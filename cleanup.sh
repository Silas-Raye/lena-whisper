#!/bin/bash
# cleanup.sh — delete participants' files from ACCRE once their results are
# on the lab server, and tidy up what stopped jobs and old setups left behind.
#
# Usage (on the ACCRE gateway):
#   bash ~/lena-whisper/cleanup.sh <participant_id> [<participant_id> ...]
#   (an ID like 1006 means each of that child's recordings on ACCRE)
#   bash ~/lena-whisper/cleanup.sh              (only the tidy-up)
#
# For each participant, after you confirm, it deletes:
#   rawAudio/<participant>.wav, rawAudio/<ID4>/<participant>.wav   the recording
#   chunkedAudioInput/<ID4>/<participant>/                         chunks
#   <ID>_output/transcriptOut/<participant>/                       transcripts
#   <ID>_output/cryOut/<participant>_cry.csv                       cry and TV detection
#   <ID>_output/combinedOut/<participant>_*.csv                    combined CSVs
#   itsFiles/<participant>.its, itsFiles/<.its name>.its           the .its file
# and removes the ID from participant_ids.txt. The .its files are the ones
# named <participant>.its and the lookup table's files for that recorder at
# TIMEPOINT; it leaves them if LW_ITS_DIR points at a folder the lab shares.
# It skips participants with a job still queued or running.
#
# Every run also removes, without asking:
#   - unfinished output files (*.partial) from jobs that stopped partway
#   - temporary install files from a setup that stopped partway
#   - lists in runs/ that no queued job needs
# and offers to delete ~/whisper-env, which older versions of setup made.

set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
SHOW_DIR="${LW_DIR/#"$HOME"/"~"}"

show() { echo "${1/#"$HOME"/"~"}"; }

# Print the size of each existing path, or nothing if none exist.
sizes() {
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then
            printf "      %-8s %s\n" "$(du -sh "$p" 2>/dev/null | cut -f1)" "$(show "$p")"
        fi
    done
}

# Delete lines for one participant from participant_ids.txt, cleaning each
# line the way clean_ids does before comparing it. Other lines stay as they are.
remove_from_list() {
    local tmp
    [ -f "$LW_IDS_FILE" ] || return 0
    tmp=$(mktemp "${LW_IDS_FILE}.XXXXXX")
    awk -v pid="$1" '{
        id = $0
        if (NR == 1) sub(/^\xEF\xBB\xBF/, "", id)
        sub(/\r$/, "", id); sub(/#.*/, "", id)
        sub(/^[[:space:]]+/, "", id); sub(/[[:space:]]+$/, "", id)
        sub(/\.[wW][aA][vV]$/, "", id)
        if (id != pid) print
    }' "$LW_IDS_FILE" > "$tmp"
    mv "$tmp" "$LW_IDS_FILE"
}

# ---- 1. Participants -------------------------------------------------------
pids=()
ids=()
for arg in "$@"; do
    id="${arg%.[wW][aA][vV]}"
    # Only plain IDs, so a typo can't turn into a path like "*" or "../".
    if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{3,}$ ]]; then
        echo "[X] '${arg}' doesn't look like a participant ID (for example 1006)."
        exit 1
    fi
    ids+=("$id")
    while IFS= read -r pid; do
        pids+=("$pid")
    done < <(recording_ids <(echo "$id"))
done

if [ "${#pids[@]}" -gt 0 ]; then
    busy=$(queued_participants whisper_subject,cry_subject)
    # Other people's recordings may need the .its files in a shared folder.
    own_its=1
    if [ -n "${LW_ITS_DIR:-}" ]; then
        own_its=0
        echo "[~] Keeping the .its files: LW_ITS_DIR points at a folder others may use."
    fi
    to_delete=()
    keep=()
    echo "[*] Files to delete:"
    for pid in "${pids[@]}"; do
        if grep -qxF "$pid" <<< "$busy"; then
            echo "    ${pid}: a job for it is queued or running (squeue --me -r). Wait"
            echo "      for it to finish, or cancel it with scancel <JOBID>; skipping."
            continue
        fi
        id4="${pid:0:4}"
        paths=(
            "${RAW_DIR}/${pid}.wav" "${RAW_DIR}/${id4}/${pid}.wav"
            "${CHUNK_DIR}/${id4}/${pid}"
            "$(transcript_dir "$pid")"
            "$(cry_path "$pid")" "$(cry_path "$pid").partial"
            "$(combined_path "$pid")" "$(combined_path "$pid").partial"
        )
        for f in "$(dirname "$(combined_path "$pid")")/${pid}"_*.csv; do
            if [ -e "$f" ] && [ "$f" != "$(combined_path "$pid")" ]; then
                paths+=("$f")
            fi
        done
        if [ "$own_its" = 1 ]; then
            its_files=("$pid")
            if [ -f "$LOOKUP_TABLE" ]; then
                while IFS= read -r name; do
                    its_files+=("$name")
                done < <(its_names "$pid")
            fi
            for name in "${its_files[@]}"; do
                paths+=("${ITS_DIR}/${name}.its" "${ITS_DIR}/${id4}/${name}.its")
            done
        fi
        found=$(sizes "${paths[@]}")
        echo "    ${pid}:"
        if [ -n "$found" ]; then
            echo "$found"
        else
            echo "      (no files on ACCRE)"
        fi
        if [ ! -f "$(combined_path "$pid")" ] && [ -n "$found" ]; then
            echo "      [!] No combined CSV yet. Make it first (combine_subjects.sh) unless"
            echo "          you're sure you don't need these files any more."
        fi
        to_delete+=("${paths[@]}")
        keep+=("$pid")
    done

    if grep -qxF "?" <<< "$busy"; then
        echo
        echo "[!] Some of your jobs are for participants this script can't identify."
        echo "    If one of them uses these files, it will fail when they're deleted."
    fi

    if [ "${#keep[@]}" -gt 0 ]; then
        echo
        echo "    ACCRE doesn't back up /nobackup. Delete these only after the"
        echo "    results are on the lab server."
        read -r -p "    Delete them and remove the IDs from participant_ids.txt? [y/N] " answer || answer=""
        if [[ "$answer" =~ ^[Yy] ]]; then
            rm -rf -- "${to_delete[@]}"
            for pid in "${keep[@]}"; do
                remove_from_list "$pid"
                # Remove the <ID4> and <ID>_output folders if they're now empty.
                out=$(output_dir "$pid")
                for dir in "${RAW_DIR}/${pid:0:4}" "${CHUNK_DIR}/${pid:0:4}" "${ITS_DIR}/${pid:0:4}" \
                        "${out}/transcriptOut" "${out}/cryOut" "${out}/combinedOut" "$out"; do
                    rmdir "$dir" 2>/dev/null || true
                done
                echo "    [✓] Deleted ${pid}'s files and removed it from participant_ids.txt"
            done
            # An ID like 1006 leaves the list once none of its recordings is busy.
            for id in "${ids[@]}"; do
                if ! grep -qE "^${id}(_|$)" <<< "$busy"; then
                    remove_from_list "$id"
                fi
            done
        else
            echo "    Nothing deleted."
        fi
    fi
    echo
fi

# ---- 2. Leftovers from stopped jobs and setups -------------------------------
echo "[*] Tidying up leftovers..."

# A job writes <name>.partial and renames it when it's complete, which takes
# seconds, so a .partial file more than an hour old is from a job that stopped.
# (Whisper's chunkedAudioInput/.../*_temp.wav files stay: they tell the next
# job to redo chunking that stopped partway.)
n=0
for dir in "$DATA_ROOT"/*_output; do
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' f; do
            rm -f -- "$f"
            n=$((n + 1))
        done < <(find "$dir" -name "*.partial" -mmin +60 -print0)
    fi
done
echo "    [✓] Unfinished output files removed: ${n}"

# setup.sh unpacks installs here and deletes the folder when it finishes.
pip_tmp="${DATA_ROOT}/.pip-tmp"
if [ -d "$pip_tmp" ]; then
    if pgrep -u "$USER" -f "pip install" >/dev/null 2>&1; then
        echo "    [~] $(show "$pip_tmp") is in use by an install that's running; left it"
    else
        rm -rf -- "$pip_tmp"
        echo "    [✓] Removed temporary install files ($(show "$pip_tmp"))"
    fi
fi

# Each submission saves its participant list in runs/; queued tasks read
# theirs when they start. Keep the lists of queued jobs, and any from the
# last day in case a submission is happening right now.
if [ -d "${LW_DIR}/runs" ]; then
    in_use=$( { squeue --me -h -r -n whisper_subject,cry_subject -o "%i %k" 2>/dev/null || true; } \
        | while read -r job comment; do
            echo "$comment"
            scontrol show job "$job" 2>/dev/null | sed -n 's/^ *Command=[^ ]* //p'
        done | grep "/runs/" || true)
    if [ -n "$(squeue --me -h -n whisper_subject,cry_subject 2>/dev/null || true)" ] && [ -z "$in_use" ]; then
        echo "    [~] Kept runs/: couldn't tell which lists your queued jobs use"
    else
        n=0
        while IFS= read -r -d '' f; do
            if ! grep -qxF "$f" <<< "$in_use"; then
                rm -f -- "$f"
                n=$((n + 1))
            fi
        done < <(find "${LW_DIR}/runs" -name "*.txt" -mtime +0 -print0)
        echo "    [✓] Old participant lists removed from ${SHOW_DIR}/runs: ${n}"
    fi
fi

# Older versions of setup.sh made the Whisper environment in your home
# folder. The pipeline now uses the one in this folder.
old_env="${HOME}/whisper-env"
if [ -d "$old_env" ] && [ "$old_env" != "$VENV_DIR" ]; then
    if [ -f "${VENV_DIR}/bin/activate" ]; then
        echo
        echo "    ~/whisper-env is from an older setup; the pipeline now uses"
        echo "    $(show "$VENV_DIR"). Deleting the old one frees $(du -sh "$old_env" 2>/dev/null | cut -f1)."
        read -r -p "    Delete ~/whisper-env? [y/N] " answer || answer=""
        if [[ "$answer" =~ ^[Yy] ]]; then
            rm -rf -- "$old_env"
            echo "    [✓] Deleted ~/whisper-env"
        fi
    else
        echo "    [~] ~/whisper-env is from an older setup. Run setup.sh, then run this"
        echo "        again to delete it."
    fi
fi

echo "[✓] Done."
