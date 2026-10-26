#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
batchCryDetection.py — ACCRE cry detection with YAMNet
For a single participant: scores every second of the recording for infant
crying with YAMNet, Google's sound event classifier.

submit_cry_subjects.sh runs this script for you. To run it by hand inside a
CPU job:
    python batchCryDetection.py <participant_id>
    e.g. python batchCryDetection.py 1243_029768

It reads the same 5-minute chunks that Whisper transcribes (16 kHz, mono),
which the first Whisper job for a participant cuts from the recording, and
writes one row per second of the recording:
    /nobackup/userspace/<VUNetID>/chunkedAudioInput/<ID4>/<participant>/   input
    /nobackup/userspace/<VUNetID>/cryOut/<ID4>/<participant>_cry.csv       output

    second          seconds since the start of the recording (0, 1, 2, ...)
    cry             1 if baby_cry is at least the threshold, otherwise 0
    baby_cry        YAMNet's score for "Baby cry, infant cry", from 0 to 1
    crying_sobbing  its score for "Crying, sobbing" (crying at any age)
    whimper         its score for "Whimper"

YAMNet scores 0.96-second windows that start every 0.48 seconds; a second's
score is the highest score among the windows centred in it. The threshold is
CRY_THRESHOLD in config.sh. YAMNet is in cry_model/yamnet (Apache 2.0); see
cry_model/README.md.

Other ways to run it:
    python batchCryDetection.py --chunks <folder> --out <file.csv>
    python batchCryDetection.py --check     # load YAMNet and stop
"""

import os
import re
import sys
import csv
import glob
import time
import getpass
import argparse

# TensorFlow prints several lines of start-up notes unless this is set first.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np

# ============================================================
# CONFIGURATION
# ============================================================
# run_cry_subject.sh sets these from config.sh. The defaults match it.
USER       = os.environ.get("USER") or getpass.getuser()
DATA_ROOT  = os.environ.get("LW_DATA_ROOT", f"/nobackup/userspace/{USER}")
CHUNK_ROOT = os.path.join(DATA_ROOT, "chunkedAudioInput")
CRY_ROOT   = os.environ.get("LW_CRY_DIR", os.path.join(DATA_ROOT, "cryOut"))
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR  = os.environ.get("LW_CRY_MODEL", os.path.join(SCRIPT_DIR, "cry_model", "yamnet"))
THRESHOLD  = float(os.environ.get("LW_CRY_THRESHOLD", "0.5"))
THREADS    = int(os.environ.get("SLURM_CPUS_PER_TASK") or os.cpu_count() or 1)

# ============================================================
# YAMNET SETTINGS
# ============================================================
SR = 16000                # YAMNet's sample rate, which Whisper's chunks also use
WINDOW_SAMPLES = 15600    # one window: 0.96 s of spectrogram, plus its last 25 ms frame
HOP_SAMPLES = 7680        # a window starts every 0.48 s
# The scores saved for each second: CSV column -> (index, name) in YAMNet's class map
CLASSES = {
    "baby_cry":       (20, "Baby cry, infant cry"),
    "crying_sobbing": (19, "Crying, sobbing"),
    "whimper":        (21, "Whimper"),
}


# ============================================================
# MODEL
# ============================================================
def class_names(model_dir):
    with open(os.path.join(model_dir, "assets", "yamnet_class_map.csv"), newline="") as f:
        return [row["display_name"] for row in csv.DictReader(f)]


def load_yamnet(model_dir=MODEL_DIR):
    """Load YAMNet, and check that it's the model this script expects."""
    if not os.path.isfile(os.path.join(model_dir, "saved_model.pb")):
        sys.exit(f"[X] YAMNet isn't in {model_dir}. It comes with this repository "
                 "(cry_model/yamnet); see cry_model/README.md.")
    import tensorflow as tf
    tf.config.threading.set_intra_op_parallelism_threads(THREADS)
    tf.config.threading.set_inter_op_parallelism_threads(2)
    model = tf.saved_model.load(model_dir)
    names = class_names(model_dir)
    for column, (index, name) in CLASSES.items():
        if len(names) != 521 or names[index] != name:
            sys.exit(f"[X] {model_dir} isn't the YAMNet model this script expects "
                     f"(class {index} should be '{name}').")
    scores = model(np.zeros(WINDOW_SAMPLES, dtype=np.float32))[0]
    if tuple(scores.shape) != (1, 521):
        sys.exit(f"[X] YAMNet gave scores of shape {tuple(scores.shape)}; expected (1, 521).")
    return model


# ============================================================
# SCORING
# ============================================================
def list_chunks(folder):
    """[(chunk number, path)] of the chunks in a folder, in order.

    Stops if batchWhisper.py hasn't finished making them: its temporary file
    is still there, or a chunk number is missing.
    """
    if glob.glob(os.path.join(folder, "*_temp.wav")):
        sys.exit(f"[X] Whisper's job is still cutting the recording into chunks, or "
                 f"stopped partway through ({folder}). Run submit_whisper_subjects.sh, "
                 "and start cry detection once status.sh shows the participant in progress.")
    chunks = []
    for path in glob.glob(os.path.join(folder, "*_audiochunk_*.wav")):
        m = re.search(r"_audiochunk_(\d+)\.wav$", path)
        if m:
            chunks.append((int(m.group(1)), path))
    chunks.sort()
    if not chunks:
        sys.exit(f"[X] No chunks in {folder}. The first Whisper job makes them: "
                 "run submit_whisper_subjects.sh.")
    if [n for n, _ in chunks] != list(range(len(chunks))):
        sys.exit(f"[X] Some chunk numbers are missing in {folder}.")
    return chunks


def score_chunks(chunks, model, log=print):
    """Each second's highest YAMNet scores, for the classes in CLASSES.

    The chunks are consecutive pieces of one recording. ffmpeg cuts them
    within a few hundredths of a second of every 5 minutes, so the windows
    are placed as if YAMNet ran on the whole recording at once: every 0.48 s
    from its start. Each chunk gives the windows that start in it, completed
    with audio from the start of the next chunk.
    """
    import soundfile as sf
    lengths = []
    for _, path in chunks:
        info = sf.info(path)
        if info.samplerate != SR or info.channels != 1:
            sys.exit(f"[X] {path} isn't 16 kHz mono audio, as Whisper's chunks are.")
        lengths.append(info.frames)
    n_seconds = sum(lengths) // SR
    best = np.zeros((n_seconds, len(CLASSES)), dtype=np.float32)
    columns = [index for index, _ in CLASSES.values()]

    t_start = time.time()
    offset = 0                                   # samples before this chunk
    for i, (number, path) in enumerate(chunks):
        end = offset + lengths[i]
        first = -(-offset // HOP_SAMPLES)        # the first window that starts in this chunk
        stop = -(-end // HOP_SAMPLES)            # the first window that starts after it
        if stop > first:
            y, _ = sf.read(path, start=first * HOP_SAMPLES - offset, dtype="float32")
            if i + 1 < len(chunks):
                following, _ = sf.read(chunks[i + 1][1], frames=WINDOW_SAMPLES, dtype="float32")
                y = np.concatenate([y, following])
            scores = model(y)[0].numpy()[: stop - first, columns]
            centres = HOP_SAMPLES * np.arange(first, first + len(scores)) + WINDOW_SAMPLES // 2
            seconds = centres // SR
            keep = seconds < n_seconds
            np.maximum.at(best, seconds[keep], scores[keep])
        offset = end
        if (i + 1) % 24 == 0 or i + 1 == len(chunks):
            log(f"  [*] Scored chunk {i + 1}/{len(chunks)} ({time.time() - t_start:.0f} s)")
    return best


def write_csv(best, out_path, threshold=THRESHOLD):
    """Write one row per second. The file appears only when it's complete."""
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    partial = out_path + ".partial"
    scores = np.round(best.astype(np.float64), 4)    # cry follows the score as written
    with open(partial, "w", newline="") as f:
        writer = csv.writer(f, lineterminator="\n")
        writer.writerow(["second", "cry"] + list(CLASSES))
        for second, row in enumerate(scores):
            writer.writerow([second, int(row[0] >= threshold)] + [f"{v:.4f}" for v in row])
    os.replace(partial, out_path)
    return int(np.sum(scores[:, 0] >= threshold))


# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(
        description="Score each second of a recording for infant crying with YAMNet.")
    parser.add_argument("participant_id", nargs="?", help="for example 1243_029768")
    parser.add_argument("--chunks", help="a folder of Whisper chunks to use instead of a "
                                         "participant's")
    parser.add_argument("--out", help="where to write the CSV (with --chunks)")
    parser.add_argument("--overwrite", action="store_true",
                        help="redo a participant whose CSV already exists")
    parser.add_argument("--check", action="store_true", help="load YAMNet and stop")
    args = parser.parse_args()

    if args.check:
        load_yamnet()
        import tensorflow as tf
        print(f"[✓] YAMNet loads (TensorFlow {tf.__version__})")
        return
    if args.chunks:
        if not args.out:
            parser.error("--chunks needs --out")
        folder, out_path, label = args.chunks, args.out, args.chunks
    elif args.participant_id:
        pid = args.participant_id
        folder = os.path.join(CHUNK_ROOT, pid[:4], pid)
        out_path = os.path.join(CRY_ROOT, pid[:4], f"{pid}_cry.csv")
        label = pid
        if os.path.exists(out_path) and not args.overwrite:
            print(f"[~] Already done: {out_path}")
            return
    else:
        parser.error("give a participant ID, --chunks, or --check")

    chunks = list_chunks(folder)
    print(f"\n{'='*50}")
    print(f"[*] Participant:  {label}")
    print(f"[*] Chunks:       {len(chunks)} in {folder}")
    print(f"[*] Output:       {out_path}")
    print(f"[*] Threshold:    baby_cry >= {THRESHOLD}")
    print(f"[*] CPU threads:  {THREADS}")
    print(f"{'='*50}\n")

    t_start = time.time()
    model = load_yamnet()
    best = score_chunks(chunks, model)
    n_cry = write_csv(best, out_path)
    print(f"\n[✓] {n_cry} of {len(best)} seconds at or above the threshold "
          f"({100.0 * n_cry / max(len(best), 1):.1f}%)")
    print(f"    Output: {out_path}")
    print(f"    Took {(time.time() - t_start) / 60:.1f} minutes")


if __name__ == "__main__":
    main()
