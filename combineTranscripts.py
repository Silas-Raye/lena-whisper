#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
combineTranscripts.py — one CSV per recording, with the Whisper transcript,
LENA's .its data, and cry detection on a single timeline.

This is the Python version of combineTranscripts_JSON.R, extended with the
.its file and cry detection. combine_subjects.sh runs it for every
participant in participant_ids.txt. To run it by hand on ACCRE:
    python3 combineTranscripts.py <participant_id> [<participant_id> ...]
    e.g. python3 combineTranscripts.py 1243_029768

It needs Python 3.9 or newer and no extra packages. By default it reads, in
/nobackup/userspace/<VUNetID>/:
    transcriptOut/<ID4>/<participant>/   Whisper's JSON files, one per chunk
    cryOut/<ID4>/<participant>_cry.csv   YAMNet cry detection, one row per second
    itsFiles/                            .its files and the lookup table
and writes combinedOut/<ID4>/<participant>_combined.csv.

To combine copies somewhere else, such as on the lab server, name the files:
    python3 combineTranscripts.py 1243_029768 --transcripts <JSON folder> \\
        --cry <cry CSV> --its <.its file> --out <combined CSV>
Leave a source out with --no-cry or --no-its. The README lists the columns.

How the times line up:
  * Every time is in seconds from the start of the recording, which is the
    same moment in the .wav file, the .its file, and cry detection.
  * batchWhisper.py cuts the recording into 5-minute chunks from the start of
    the file, so chunk N starts at N x 300 seconds. Whisper's times are from
    the start of their chunk, so this script adds the chunk's start.
  * The .its file gives the clock time at which the recording started, so
    every row also gets a wall-clock time.
  * LENA's 5-minute blocks follow the wall clock instead of the start of the
    file: a recording that starts at 10:48 has a 2-minute first block, then
    5-minute blocks, and its last block can be short too. lena_block numbers
    those blocks, so a Whisper chunk usually spans two of them.
"""

import os
import re
import sys
import csv
import json
import glob
import math
import bisect
import getpass
import argparse
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:          # Python 3.8 and older
    ZoneInfo = None

# ============================================================
# CONFIGURATION
# ============================================================
# combine_subjects.sh passes these from config.sh. The defaults match it.
USER      = os.environ.get("USER") or getpass.getuser()
DATA_ROOT = os.environ.get("LW_DATA_ROOT", f"/nobackup/userspace/{USER}")

# batchWhisper.py cuts each recording into chunks of this many seconds,
# starting at the beginning of the file.
CHUNK_SECONDS = 300

# The CSV's columns, in order. The README describes each one.
COLUMNS = [
    "participant_id", "source", "start_sec", "end_sec", "clock_start", "clock_end",
    "lena_block",
    # Whisper
    "text", "whisper_chunk", "avg_logprob", "no_speech_prob", "compression_ratio",
    # LENA
    "speaker", "lena_conversation", "adult_words", "child_utterances",
    "child_utterance_sec", "child_cry_vfx_sec", "conversational_turns",
    "average_db", "peak_db",
    # What overlaps each row
    "cry_sec", "cry_score", "lena_speakers",
]
# Rows that start at the same time are listed in this order.
SOURCE_ORDER = {"lena_block": 0, "lena_segment": 1, "cry": 2, "whisper": 3}


class CombineError(Exception):
    """A participant can't be combined yet; the message says why."""


# ============================================================
# HELPERS
# ============================================================
def seconds(text):
    """'PT12.34S', 'P79.00S', or 'PT1H2M3.4S' in an .its file -> seconds."""
    m = re.fullmatch(r"P(?:T)?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?", text.strip())
    if not m:
        raise ValueError(f"unexpected time in .its file: {text!r}")
    h, mi, s = m.groups()
    return int(h or 0) * 3600 + int(mi or 0) * 60 + float(s or 0)


def utc_time(text):
    """'2020-10-26T11:58:41Z' (or with fractions of a second) -> UTC datetime."""
    m = re.fullmatch(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z?", text.strip())
    if not m:
        raise ValueError(f"unexpected clock time in .its file: {text!r}")
    *parts, frac = m.groups()
    t = datetime(*map(int, parts), tzinfo=timezone.utc)
    return t + timedelta(seconds=float(frac or 0))


def fmt(x, places=2):
    return "" if x is None else f"{x:.{places}f}"


def number_ranges(numbers):
    """[3, 4, 5, 9] -> '3-5, 9'"""
    out, numbers = [], sorted(numbers)
    for i, n in enumerate(numbers):
        if i and n == numbers[i - 1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in out)


def id_number(participant_id):
    """'1243_029768' -> '1243': the child's ID, before the recorder number."""
    return participant_id.split("_", 1)[0]


# ============================================================
# WHISPER
# ============================================================
def read_whisper(folder, participant_id, recording_end=None):
    """Rows for every Whisper segment in a participant's JSON folder.

    Like combineTranscripts_JSON.R, but with each segment's time measured
    from the start of the recording instead of the start of its chunk.
    Whisper pads the end of each chunk with silence and sometimes invents
    text there ("Music", or one word repeated every few seconds) with times
    past the end of the chunk. Those would land on the next chunk's part of
    the timeline, so segments that start after the end of their chunk (or of
    the recording) are left out, and segments that run past the end of their
    chunk are cut at it.
    Returns (rows, chunk numbers found).
    """
    rows, chunks, dropped, cut = [], set(), 0, 0
    for path in glob.glob(os.path.join(folder, "*.json")):
        m = re.search(r"_audiochunk_(\d+)\.json$", path)
        if not m:
            print(f"  [~] Skipping {os.path.basename(path)}: not a Whisper chunk file")
            continue
        chunk = int(m.group(1))
        chunks.add(chunk)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except ValueError:
            raise CombineError(f"{path} is damaged (a job probably stopped while writing "
                               "it). Delete it and run submit_whisper_subjects.sh to redo "
                               "that chunk.")
        offset = chunk * CHUNK_SECONDS
        limit = offset + CHUNK_SECONDS
        last_start = limit if recording_end is None else min(limit, recording_end)
        for seg in data.get("segments") or []:
            start, end = offset + float(seg["start"]), offset + float(seg["end"])
            if start >= last_start:
                dropped += 1
                continue
            if end > limit:
                end, cut = limit, cut + 1
            rows.append({
                "participant_id": participant_id,
                "source": "whisper",
                "start": start,
                "end": end,
                "text": (seg.get("text") or "").strip(),
                "whisper_chunk": chunk,
                "avg_logprob": seg.get("avg_logprob"),
                "no_speech_prob": seg.get("no_speech_prob"),
                "compression_ratio": seg.get("compression_ratio"),
            })
    if dropped or cut:
        print(f"  [~] Whisper: left out {dropped} segments that start after the end of "
              f"their chunk, and cut {cut} that run past it")
    return rows, chunks


# ============================================================
# CRY DETECTION
# ============================================================
def read_cry(path):
    """batchCryDetection.py's per-second cry predictions (0/1), and YAMNet's
    "Baby cry, infant cry" score for each second (None for CSVs without one)."""
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    cry = [int(row["cry"]) for row in rows]
    scores = [float(row["baby_cry"]) for row in rows] if rows and "baby_cry" in rows[0] else None
    return cry, scores


def cry_episodes(cry):
    """[(start, end)] of each run of seconds marked as crying."""
    episodes, start = [], None
    for second, value in enumerate(cry + [0]):
        if value and start is None:
            start = second
        elif not value and start is not None:
            episodes.append((start, second))
            start = None
    return episodes


# ============================================================
# LENA .its FILES
# ============================================================
class Its:
    """The parts of a LENA .its file that go on the timeline."""

    def __init__(self, path):
        self.path = path
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as e:
            raise CombineError(f"can't read {path} as an .its file ({e})")
        units = root.findall("ProcessingUnit")
        # One <Recording> per stretch the recorder ran. The audio of all of
        # them is one continuous .wav file; the clock jumps between them.
        self.recordings = []
        self.segments = []
        self.blocks = []
        for unit in units:
            for rec in unit.findall("Recording"):
                self.recordings.append((seconds(rec.get("startTime")),
                                        seconds(rec.get("endTime")),
                                        utc_time(rec.get("startClockTime"))))
                for part in rec:                 # <Pause> and <Conversation>
                    conversation = part.get("num") if part.tag == "Conversation" else None
                    for seg in part.findall("Segment"):
                        self.segments.append(self._segment(seg, conversation))
            for section in unit.iter("FiveMinuteSection"):
                self.blocks.append(self._block(section))
        if not self.recordings:
            raise CombineError(f"{os.path.basename(path)} has no <Recording> in it")
        self.segments.sort(key=lambda s: s["start"])
        self.blocks.sort(key=lambda b: b["start"])
        for number, block in enumerate(self.blocks, start=1):
            block["lena_block"] = number
        self.duration = max(end for _, end, _ in self.recordings)
        self._rec_starts = [start for start, _, _ in self.recordings]
        self._seg_starts = [s["start"] for s in self.segments]
        self._block_starts = [b["start"] for b in self.blocks]
        self.zone, self.zone_note = self._time_zone(root)
        recorder = root.find(".//SRDInfo")
        self.serial = recorder.get("SerialNumber") if recorder is not None else None

    @staticmethod
    def _segment(seg, conversation):
        a = seg.attrib
        words = [float(a[k]) for k in ("femaleAdultWordCnt", "maleAdultWordCnt") if k in a]
        return {
            "source": "lena_segment",
            "start": seconds(a["startTime"]),
            "end": seconds(a["endTime"]),
            "speaker": a.get("spkr", ""),
            "lena_conversation": conversation,
            "adult_words": fmt(sum(words)) if words else None,
            "child_utterances": a.get("childUttCnt"),
            "child_utterance_sec": fmt(seconds(a["childUttLen"])) if "childUttLen" in a else None,
            "child_cry_vfx_sec": fmt(seconds(a["childCryVfxLen"])) if "childCryVfxLen" in a else None,
            "average_db": a.get("average_dB"),
            "peak_db": a.get("peak_dB"),
        }

    @staticmethod
    def _block(section):
        a = section.attrib
        return {
            "source": "lena_block",
            "start": seconds(a["startTime"]),
            "end": seconds(a["endTime"]),
            "adult_words": a.get("adultWordCnt"),
            "child_utterances": a.get("childUttCnt"),
            "child_utterance_sec": fmt(seconds(a["childUttLen"])) if "childUttLen" in a else None,
            "child_cry_vfx_sec": fmt(seconds(a["childCryVfxLen"])) if "childCryVfxLen" in a else None,
            "conversational_turns": a.get("turnTaking"),
            "average_db": a.get("average_dB"),
            "peak_db": a.get("peak_dB"),
        }

    @staticmethod
    def _time_zone(root):
        """The local time zone that the .its file records, for wall-clock times."""
        transfer = root.find(".//TransferTime")
        name = transfer.get("TimeZone") if transfer is not None else None
        if name and ZoneInfo is not None:
            try:
                return ZoneInfo(name), name
            except Exception:
                pass
        zone = root.find(".//Audio/TimeZone")
        if zone is not None and zone.get("StandardSecondsOffset"):
            offset = int(zone.get("StandardSecondsOffset"))
            return (timezone(timedelta(seconds=offset)),
                    f"UTC{offset / 3600:+g} (standard time; daylight saving not applied)")
        return timezone.utc, "UTC (the .its file names no time zone)"

    def clock(self, t):
        """Local wall-clock time, as text, of t seconds into the recording."""
        i = max(bisect.bisect_right(self._rec_starts, t) - 1, 0)
        start, _, start_clock = self.recordings[i]
        local = (start_clock + timedelta(seconds=round(t - start, 2))).astimezone(self.zone)
        return f"{local:%Y-%m-%d %H:%M:%S}.{local.microsecond // 10000:02d}"

    def block_at(self, t):
        """The number of the LENA 5-minute block that contains second t."""
        i = bisect.bisect_right(self._block_starts, t) - 1
        if 0 <= i and t < self.blocks[i]["end"] + 1e-6:
            return self.blocks[i]["lena_block"]
        return None

    def speakers_during(self, a, b):
        """LENA's labels between seconds a and b, with seconds, most first."""
        totals = {}
        i = max(bisect.bisect_right(self._seg_starts, a) - 1, 0)
        while i < len(self.segments) and self.segments[i]["start"] < b:
            seg = self.segments[i]
            overlap = min(b, seg["end"]) - max(a, seg["start"])
            if overlap > 0:
                totals[seg["speaker"]] = totals.get(seg["speaker"], 0.0) + overlap
            i += 1
        ranked = sorted(totals.items(), key=lambda kv: -kv[1])
        return "; ".join(f"{label} {sec:.2f}" for label, sec in ranked if sec >= 0.005)


def read_lookup_tables(its_dir):
    """Rows of every lookup table in its_dir: any CSV with ExternalReferenceID
    and ITS_File_Name columns, such as its_identifier_file_babies_crb.csv."""
    rows = []
    for path in sorted(glob.glob(os.path.join(its_dir, "*.csv"))):
        with open(path, newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            fields = {name.strip(): name for name in (reader.fieldnames or [])}
            if "ExternalReferenceID" not in fields or "ITS_File_Name" not in fields:
                continue
            for row in reader:
                rows.append(((row[fields["ExternalReferenceID"]] or "").strip(),
                             (row[fields["ITS_File_Name"]] or "").strip(),
                             os.path.basename(path)))
    return rows


def find_its(participant_id, its_dir):
    """The path of a participant's .its file in its_dir.

    A file named <participant>.its wins. Otherwise the lookup table finds it:
    the row whose ExternalReferenceID starts with the participant's ID number
    (1243_12mo for 1243_029768) and whose ITS_File_Name ends with the same
    recorder number (20211105_123641_029768). The same child can wear the
    same recorder at more than one age, so if several of those files are in
    its_dir, you choose (see the error message).
    """
    child = id_number(participant_id)
    recorder = participant_id.split("_", 1)[1] if "_" in participant_id else ""
    folders = [its_dir, os.path.join(its_dir, participant_id[:4])]

    def on_disk(name):
        name = name[:-4] if name.lower().endswith(".its") else name
        return next((p for p in (os.path.join(d, name + ".its") for d in folders)
                     if os.path.isfile(p)), None)

    named = on_disk(participant_id)
    if named:
        return named

    tables = read_lookup_tables(its_dir)
    if not tables:
        raise CombineError(f"no .its file named {participant_id}.its, and no lookup table "
                           f"(a CSV with ExternalReferenceID and ITS_File_Name columns) in {its_dir}")
    candidates = []
    for external_id, its_name, _ in tables:
        m = re.match(r"\d+", external_id)
        name = its_name[:-4] if its_name.lower().endswith(".its") else its_name
        if m and m.group(0) == child and "_".join(name.split("_")[2:]) == recorder:
            if name not in [c[1] for c in candidates]:
                candidates.append((external_id, name))
    if not candidates:
        raise CombineError(f"no row in the lookup table matches {participant_id} "
                           f"(ID {child}, recorder {recorder})")
    found = [(ext, name, on_disk(name)) for ext, name in candidates]
    present = [f for f in found if f[2]]
    if len(present) == 1:
        return present[0][2]
    if not present:
        names = ", ".join(f"{name}.its ({ext})" for ext, name, _ in found)
        raise CombineError(f"the lookup table names {names}, but it isn't in {its_dir}")
    choices = "\n".join(f"        {ext:<12} {path}" for ext, _, path in present)
    raise CombineError(
        f"{len(present)} .its files match {participant_id}; the same child wore that "
        f"recorder at more than one age:\n{choices}\n"
        f"    Copy the one for this recording to {participant_id}.its in the same "
        f"folder, then run this again:\n"
        f"        cp {present[0][2]} {os.path.join(its_dir, participant_id + '.its')}")


# ============================================================
# COMBINE
# ============================================================
def combine(participant_id, transcripts=None, cry_path=None, its_path=None,
            skip_checks=False):
    """All rows for one participant, sorted by time. Sources set to None are
    left out. Raises CombineError if the sources don't fit together."""
    rows, problems = [], []

    its = Its(its_path) if its_path else None
    if its:
        print(f"  [*] .its file: {os.path.basename(its_path)} "
              f"({its.duration / 3600:.2f} hours, {len(its.segments)} segments, "
              f"{len(its.blocks)} 5-minute blocks; clock times in {its.zone_note})")
        rows += its.blocks + its.segments
        recorder = participant_id.split("_")[1] if "_" in participant_id else ""
        if its.serial and recorder.isdigit() and its.serial.isdigit() \
                and int(its.serial) != int(recorder):
            problems.append(f"the .its file is from recorder {its.serial}, but "
                            f"{participant_id} wore recorder {recorder}")

    cry, cry_scores = read_cry(cry_path) if cry_path else (None, None)
    episodes = cry_episodes(cry) if cry is not None else []
    if cry is not None:
        print(f"  [*] Cry detection: {sum(cry)} of {len(cry)} seconds, "
              f"{len(episodes)} episodes")
        rows += [{"source": "cry", "start": float(a), "end": float(b)} for a, b in episodes]
        if its and abs(len(cry) - its.duration) > 2:
            problems.append(f"cry detection covers {len(cry)} seconds but the .its file "
                            f"covers {its.duration:.0f}; is it the right .its file?")

    if transcripts:
        end = its.duration if its else (len(cry) if cry is not None else None)
        whisper, chunks = read_whisper(transcripts, participant_id, end)
        if not chunks:
            raise CombineError(f"no Whisper JSON files in {transcripts}")
        if its:
            expected = math.ceil(its.duration / CHUNK_SECONDS - 1e-6)
        elif cry is not None:
            expected = math.ceil(len(cry) / CHUNK_SECONDS)
        else:
            expected = max(chunks) + 1
        missing = sorted(set(range(expected)) - chunks)
        extra = sorted(c for c in chunks if c >= expected)
        print(f"  [*] Whisper: {len(whisper)} segments from {len(chunks)} chunks")
        if missing:
            problems.append(f"{len(missing)} of {expected} Whisper chunks have no transcript "
                            f"(chunk {number_ranges(missing)})")
        if extra:
            problems.append(f"Whisper chunk {number_ranges(extra)} would start after the end "
                            f"of the recording in the .its file; is it the right .its file?")
        rows += whisper

    if problems and not skip_checks:
        raise CombineError("; ".join(problems) +
                           " (to write the CSV anyway, add --skip-checks)")
    for p in problems:
        print(f"  [!] {p}")

    # Put everything on one timeline: what overlaps each row, and when it was.
    cry_starts = [a for a, _ in episodes]
    for row in rows:
        row["participant_id"] = participant_id
        a, b = row["start"], row["end"]
        if its:
            row["clock_start"], row["clock_end"] = its.clock(a), its.clock(b)
            row.setdefault("lena_block", its.block_at(a))
            if row["source"] != "lena_segment":
                row["lena_speakers"] = its.speakers_during(a, b)
        if cry is not None and row["source"] != "cry":
            overlap = 0.0
            i = max(bisect.bisect_right(cry_starts, a) - 1, 0)
            while i < len(episodes) and episodes[i][0] < b:
                overlap += max(0.0, min(b, episodes[i][1]) - max(a, episodes[i][0]))
                i += 1
            row["cry_sec"] = fmt(overlap)
        if cry_scores:
            # The highest score among the seconds that the row touches
            s0 = min(max(int(math.floor(a)), 0), len(cry_scores) - 1)
            s1 = min(max(int(math.ceil(b)), s0 + 1), len(cry_scores))
            row["cry_score"] = fmt(max(cry_scores[s0:s1]), 4)
    rows.sort(key=lambda r: (r["start"], SOURCE_ORDER[r["source"]], r["end"]))
    return rows


def write_rows(rows, out_path):
    """Write the CSV. The file appears only when it's complete."""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    partial = out_path + ".partial"
    with open(partial, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(COLUMNS)
        for row in rows:
            out = dict(row, start_sec=fmt(row["start"]), end_sec=fmt(row["end"]))
            for key in ("avg_logprob", "no_speech_prob", "compression_ratio"):
                if out.get(key) is not None:
                    out[key] = fmt(out[key], 4)
            writer.writerow(["" if out.get(c) is None else out[c] for c in COLUMNS])
    os.replace(partial, out_path)


# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="Combine Whisper, .its, and cry detection output into one CSV "
                    "per recording.")
    parser.add_argument("participant_ids", nargs="+", metavar="participant_id")
    parser.add_argument("--data-root", default=DATA_ROOT,
                        help="folder with transcriptOut, cryOut, and combinedOut "
                             "(default: %(default)s)")
    parser.add_argument("--its-dir", help="folder with the .its files and lookup table "
                                          "(default: <data-root>/itsFiles)")
    parser.add_argument("--cry-dir", help="default: <data-root>/cryOut")
    parser.add_argument("--out-dir", help="default: <data-root>/combinedOut")
    one = parser.add_argument_group("for one participant, files anywhere")
    one.add_argument("--transcripts", help="folder with the participant's Whisper JSON files")
    one.add_argument("--cry", help="the participant's cry detection CSV")
    one.add_argument("--its", help="the participant's .its file")
    one.add_argument("--out", help="where to write the combined CSV")
    parser.add_argument("--no-cry", action="store_true", help="leave cry detection out")
    parser.add_argument("--no-its", action="store_true", help="leave the .its data out")
    parser.add_argument("--skip-checks", action="store_true",
                        help="write the CSV even if Whisper chunks are missing, the "
                             "sources' lengths differ, or the .its file is from "
                             "another recorder")
    parser.add_argument("--overwrite", action="store_true",
                        help="redo participants whose combined CSV already exists")
    args = parser.parse_args()

    single = [o for o in ("transcripts", "cry", "its", "out") if getattr(args, o)]
    if single and len(args.participant_ids) > 1:
        parser.error(f"--{single[0]} names one participant's file; give one participant ID")
    its_dir = args.its_dir or os.path.join(args.data_root, "itsFiles")
    cry_dir = args.cry_dir or os.path.join(args.data_root, "cryOut")
    out_dir = args.out_dir or os.path.join(args.data_root, "combinedOut")

    results = []
    for pid in args.participant_ids:
        id4 = pid[:4]
        if args.transcripts:
            transcripts = args.transcripts
            # combineTranscripts_JSON.R wrote next to the JSON folder
            out_path = args.out or os.path.join(
                os.path.dirname(os.path.abspath(transcripts)), f"{pid}_combined.csv")
        else:
            transcripts = os.path.join(args.data_root, "transcriptOut", id4, pid)
            out_path = args.out or os.path.join(out_dir, id4, f"{pid}_combined.csv")
        cry_path = None if args.no_cry else (args.cry or os.path.join(cry_dir, id4, f"{pid}_cry.csv"))

        print(f"[*] {pid}")
        if os.path.exists(out_path) and not args.overwrite:
            print(f"  [~] Already combined: {out_path}")
            results.append((pid, "already combined"))
            continue
        try:
            if not os.path.isdir(transcripts):
                raise CombineError(f"no Whisper transcripts folder: {transcripts}")
            if cry_path and not os.path.isfile(cry_path):
                raise CombineError(f"no cry detection output yet: {cry_path} "
                                   "(run submit_cry_subjects.sh, or add --no-cry)")
            its_path = None
            if not args.no_its:
                its_path = args.its or find_its(pid, its_dir)
                if not os.path.isfile(its_path):
                    raise CombineError(f"no such .its file: {its_path}")
            rows = combine(pid, transcripts, cry_path, its_path, args.skip_checks)
            write_rows(rows, out_path)
        except (CombineError, ValueError, KeyError) as e:
            print(f"  [!] Not combined: {e}")
            results.append((pid, "not combined"))
            continue
        print(f"  [✓] {len(rows)} rows: {out_path}")
        results.append((pid, "combined"))

    if len(results) > 1:
        print()
        for pid, status in results:
            print(f"    {pid:<16} {status}")
    sys.exit(0 if all(s != "not combined" for _, s in results) else 1)


if __name__ == "__main__":
    main()
