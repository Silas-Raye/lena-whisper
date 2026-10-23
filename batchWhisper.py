#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
batchWhisper.py — ACCRE combined pipeline
For a single participant: chunks raw audio, then transcribes all chunks.

submit_whisper_subjects.sh runs this script for you. To run it by hand inside
a GPU session:
    python batchWhisper.py <participant_id>
    e.g. python batchWhisper.py 1243_029768

Paths come from your login name, so nobody edits this file to get started:
    /nobackup/userspace/<VUNetID>/rawAudio            recordings you upload
    /nobackup/userspace/<VUNetID>/chunkedAudioInput   5-minute chunks
    /nobackup/userspace/<VUNetID>/transcriptOut       one JSON per chunk

The script can resume. It skips chunking when it already finished, and it
skips every chunk that already has a JSON transcript. A job that hits its
time limit loses only the chunk in progress.
"""

import os
import sys
import glob
import time
import getpass
import subprocess

import torch
import whisper
from whisper.utils import get_writer

# ============================================================
# CONFIGURATION
# ============================================================
# run_whisper_subject.sh sets these from config.sh. The defaults match it.
USER        = os.environ.get("USER") or getpass.getuser()
DATA_ROOT   = os.environ.get("LW_DATA_ROOT", f"/nobackup/userspace/{USER}")
RAW_ROOT    = os.path.join(DATA_ROOT, "rawAudio")
CHUNK_ROOT  = os.path.join(DATA_ROOT, "chunkedAudioInput")
OUTPUT_ROOT = os.path.join(DATA_ROOT, "transcriptOut")
MODEL_TYPE  = os.environ.get("LW_WHISPER_MODEL", "large-v2")
# This pipeline needs a GPU. transcribe_audio() stops with a clear message
# if the job landed on a node without one.
DEVICE      = "cuda"

TRANSCRIPTION_SETTINGS = {
    "language":  "en",
    "beam_size": 5,
    "best_of":   5,
    "patience":  1.0,
    "fp16":      True,
    }

# ============================================================
# HELPERS
# ============================================================
def get_chunk_number(filepath):
    """Sort chunks numerically by trailing chunk number."""
    base = os.path.splitext(os.path.basename(filepath))[0]
    try:
        return int(base.split("_audiochunk_")[-1])
    except ValueError:
        return 0

# ============================================================
# STAGE 1 — CHUNKING
# ============================================================
def chunk_audio(participant_id):
    folder_4 = participant_id[:4]

    # Look for raw file in nested structure first, then flat
    candidates = [
        os.path.join(RAW_ROOT, folder_4, f"{participant_id}.wav"),
        os.path.join(RAW_ROOT, f"{participant_id}.wav"),
    ]
    raw_path = next((c for c in candidates if os.path.exists(c)), None)

    # Chunks go into chunkedAudioInput/1243/1243_029768/
    chunk_dir    = os.path.join(CHUNK_ROOT, folder_4, participant_id)
    chunk_prefix = os.path.join(chunk_dir, f"{participant_id}_audiochunk_")
    temp_wav     = os.path.join(chunk_dir, f"{participant_id}_temp.wav")

    # Skip if chunking already finished. The temp file is deleted only after
    # chunking succeeds, so chunks next to a leftover temp file are a partial
    # set from a job that was stopped; redo those.
    existing = glob.glob(f"{chunk_prefix}*.wav")
    if existing and not os.path.exists(temp_wav):
        print(f"[~] Already chunked ({len(existing)} chunks found), skipping")
        return chunk_dir

    if not raw_path:
        print(f"[X] No recording found for {participant_id}. Looked for:")
        for c in candidates:
            print(f"      {c}")
        print(f"    Upload it to {RAW_ROOT}/ (README: Copy files between your computer and ACCRE).")
        sys.exit(1)

    print(f"[*] Raw file: {raw_path}")
    os.makedirs(chunk_dir, exist_ok=True)

    # Step 1a — Convert to 16kHz mono wav
    print(f"[*] Converting to 16kHz mono wav...")
    result = subprocess.run([
        "ffmpeg", "-y",
        "-i", raw_path,
        "-acodec", "pcm_s16le",
        "-ar", "16000",
        "-ac", "1",
        temp_wav
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[X] ffmpeg conversion failed:")
        print(result.stderr[-300:])
        sys.exit(1)

    # Step 1b — Chunk into 5-minute segments
    print(f"[*] Chunking into 5-minute segments...")
    result = subprocess.run([
        "ffmpeg", "-y",
        "-i", temp_wav,
        "-f", "segment",
        "-segment_time", "300",
        "-c", "copy",
        "-segment_start_number", "0",
        f"{chunk_prefix}%d.wav"
    ], capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[X] ffmpeg chunking failed:")
        print(result.stderr[-300:])
        sys.exit(1)

    # Clean up temp file. Its absence marks chunking as finished.
    if os.path.exists(temp_wav):
        os.remove(temp_wav)

    chunks = glob.glob(f"{chunk_prefix}*.wav")
    print(f"[✓] Chunking complete: {len(chunks)} chunks created")
    return chunk_dir

# ============================================================
# STAGE 2 — TRANSCRIPTION
# ============================================================
def transcribe_audio(participant_id, chunk_dir):
    folder_4  = participant_id[:4]
    pattern   = os.path.join(chunk_dir, f"{participant_id}_audiochunk_*.wav")
    wav_files = sorted(glob.glob(pattern), key=get_chunk_number)

    if not wav_files:
        print(f"[X] No chunks found in: {chunk_dir}")
        sys.exit(1)

    print(f"[*] Found {len(wav_files)} chunks to transcribe")

    # Output: transcriptOut/1243/1243_029768/
    out_dir = os.path.join(OUTPUT_ROOT, folder_4, participant_id)
    os.makedirs(out_dir, exist_ok=True)

    # Chunking above runs fine without a GPU, so stop only here. The chunks
    # stay on disk, and the next run skips straight to transcription.
    if not torch.cuda.is_available():
        print("[X] No GPU on this node, so transcription can't run.")
        print("    Submit with submit_whisper_subjects.sh, which requests a GPU,")
        print("    or start an interactive_gpu session before running by hand.")
        sys.exit(1)

    print(f"[*] Loading Whisper {MODEL_TYPE} on {torch.cuda.get_device_name(0)}...")
    t_load = time.time()
    model = whisper.load_model(MODEL_TYPE, device=DEVICE)
    print(f"[✓] Model loaded in {time.time() - t_load:.0f} s")

    skipped = 0
    success = 0
    errors  = 0
    total   = len(wav_files)

    for i, wav_path in enumerate(wav_files, start=1):
        base_name   = os.path.splitext(os.path.basename(wav_path))[0]
        output_json = os.path.join(out_dir, f"{base_name}.json")

        if os.path.exists(output_json):
            skipped += 1
            continue

        if skipped and success == 0 and errors == 0:
            print(f"  [~] Skipped {skipped} chunk(s) that already have transcripts")

        print(f"  [*] Transcribing {i}/{total}: {base_name}")
        t_chunk = time.time()
        try:
            result = model.transcribe(wav_path, **TRANSCRIPTION_SETTINGS)
            writer = get_writer("json", out_dir)
            writer(result, wav_path)
            print(f"  [✓] Done: {base_name} ({time.time() - t_chunk:.0f} s)")
            success += 1
        except Exception as e:
            print(f"  [X] Error on {base_name}: {e}")
            errors += 1

    print(f"\n[*] Transcription complete:")
    print(f"    ✓ Success: {success}  ~ Skipped: {skipped}  ✗ Errors: {errors}")
    print(f"    Output: {out_dir}")

    if errors > 0:
        sys.exit(1)

# ============================================================
# MAIN
# ============================================================
def main():
    if len(sys.argv) < 2:
        print("[X] Usage: python batchWhisper.py <participant_id>")
        sys.exit(1)

    participant_id = sys.argv[1]

    print(f"\n{'='*50}")
    print(f"[*] Participant:  {participant_id}")
    print(f"[*] Model:        {MODEL_TYPE} on {DEVICE}")
    print(f"[*] Data folder:  {DATA_ROOT}")
    print(f"{'='*50}\n")

    print(f"--- STAGE 1: CHUNKING ---")
    chunk_dir = chunk_audio(participant_id)

    print(f"\n--- STAGE 2: TRANSCRIPTION ---")
    transcribe_audio(participant_id, chunk_dir)

    print(f"\n{'='*50}")
    print(f"[✓] Pipeline complete: {participant_id}")
    print(f"{'='*50}\n")

if __name__ == "__main__":
    main()
