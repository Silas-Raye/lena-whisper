# LENA Whisper transcription on ACCRE

These scripts process SEA Lab LENA recordings on ACCRE. For each recording
they:

1. Transcribe it with Whisper (`large-v2`) on ACCRE's GPUs.
2. Mark every second that has infant crying or TV/radio, using YAMNet,
   Google's sound classifier, on ACCRE's CPUs.
3. Combine the transcript, crying, TV, and the LENA `.its` data into one CSV
   on a single timeline, and also save each of them as its own CSV.

You don't edit any file paths: the scripts read your VUNetID from your ACCRE
login.

## Before you start

You need:

- An ACCRE account in the lab's group. To check, log in to ACCRE and run
  `slurm_resources`; it should list `l3_humphreys_lab_iacc` (GPU jobs) and
  `l3_humphreys_lab` (CPU jobs).
- Edit access to the
  [LENA Transcription Tracker](https://docs.google.com/spreadsheets/d/1yqIpogNROzr-JfZtk5D6msxbtlnufOJ4n0m8fmIYhx4/edit).
- Access to the lab server through the GlobalProtect VPN.
- A terminal: **Terminal** on a Mac, or **Command Prompt** on Windows.

## Set up (once)

1. Log in to ACCRE, replacing `<VUNetID>` with yours:

   ```bash
   ssh <VUNetID>@login.accre.vu
   ```

2. Copy this repository into your home folder:

   ```bash
   git clone <REPO_URL> ~/lena-whisper
   ```

   If the repository is private, GitHub asks for your username and a
   personal access token. Your GitHub password doesn't work here.

3. Run setup:

   ```bash
   bash ~/lena-whisper/setup.sh
   ```

Setup checks your access to the lab's accounts, creates your folders in
`/nobackup/userspace/<VUNetID>/`, installs Whisper and TensorFlow (about 20
minutes the first time), and writes `~/lena-whisper/my_commands.txt`, a
list of every command below. You can run setup again at any time; it skips
steps that are already done.

## Process recordings

All of these commands are in `~/lena-whisper/my_commands.txt`. To see them,
run `cat ~/lena-whisper/my_commands.txt`.

1. In the LENA Transcription Tracker, set the recordings you're taking to
   **In Progress**.

2. On ACCRE, list the participant IDs, one per line, for example `1006`:

   ```bash
   nano ~/lena-whisper/participant_ids.txt
   ```

   To save and exit nano, press Ctrl+X, then Y, then Enter. Each ID stands
   for all of that child's recordings at the age set by `TIMEPOINT` in
   `config.sh` (now `6-mo`). To process just one recording, use its full
   ID, for example `1006_029795`.

3. Copy the recordings and `.its` files to ACCRE. On ACCRE, run:

   ```bash
   bash ~/lena-whisper/print_wav_commands.sh
   bash ~/lena-whisper/print_its_commands.sh
   ```

   Each prints copy commands for Windows and Mac with your IDs, file names,
   and VUNetID filled in. Connect to the lab server (see below), then paste
   the commands for your system into a terminal on **your own computer**.
   Each `scp` asks for your VUNetID password.

   Copy the `.its` files before you start transcribing. Transcription cuts
   each recording into chunks that line up with LENA's 5-minute blocks in
   the `.its` file; without the `.its` file, it uses plain 5-minute chunks.

4. You may need to restart your shell, terminal, or command prompt and reconnect to ACCRE between steps 3. and 5.

5. Start transcription:

   ```bash
   bash ~/lena-whisper/submit_whisper_subjects.sh
   ```

6. Once `status.sh` shows a recording as `in progress`, start cry and TV
   detection:

   ```bash
   bash ~/lena-whisper/submit_cry_subjects.sh
   ```

7. Check progress, and run `submit_whisper_subjects.sh` again after each
   round of jobs until every recording shows `done` (see
   [Why you submit more than once](#why-you-submit-more-than-once)):

   ```bash
   bash ~/lena-whisper/status.sh       # transcription
   bash ~/lena-whisper/cry_status.sh   # cry and TV detection
   ```

8. Combine the results:

   ```bash
   bash ~/lena-whisper/combine_subjects.sh
   ```

9. Copy the results to the lab server. On ACCRE, run the following command,
   then paste the printed commands into a terminal on your own computer:

   ```bash
   bash ~/lena-whisper/copy_results_to_lab_server.sh
   ```

10. In the tracker, update the recordings' status.

11. Delete the participants' files from ACCRE:

    ```bash
    bash ~/lena-whisper/cleanup.sh 1006
    ```

    It lists the files and deletes them when you confirm, and removes the ID
    from `participant_ids.txt`. It keeps the `.its` files.

### Why you submit more than once

The lab's GPU access allows each person one GPU at a time, for 30 minutes per
job, and a full-day recording takes about 8 such jobs. Every finished chunk is
saved, so each time you run `submit_whisper_subjects.sh`, the next job
continues where the last one stopped. Cry and TV detection does a whole
recording in one job.

## Connect to the lab server

First connect to the GlobalProtect VPN.

**Mac:** In Finder, choose **Go > Connect to Server**, enter
`smb://vu1file.it.vanderbilt.edu/PBD/PSY/Humphreyslab`, and sign in with
your VUNetID. The server appears at `/Volumes/HumphreysLab`.

**Windows:** In File Explorer, right-click **This PC** and choose **Map
network drive**. Choose drive `X:`, enter
`\\vu1file.it.vanderbilt.edu\PBD\PSY\Humphreyslab` as the folder, clear
**Reconnect at sign-in**, select **Connect using different credentials**, and
sign in with your VUNetID. The printed commands assume drive `X:`.

## What you get

Everything the pipeline makes for a child goes in one folder on ACCRE,
`/nobackup/userspace/<VUNetID>/<ID>_output/`, for example `1006_output`:

| Folder | Contents |
|---|---|
| `transcriptOut/<recording>/` | Whisper's JSON files, one per chunk, and the chunk list. |
| `cryOut/` | `<recording>_cry.csv`, from cry and TV detection. |
| `combinedOut/` | The four CSVs below, made by `combine_subjects.sh`. |

`combinedOut` has four CSVs per recording, for example `1006_029795`:

| File | Contents |
|---|---|
| `<recording>_combined.csv` | Everything on one timeline (see below). |
| `<recording>_combined_transcripts.csv` | The Whisper transcript alone, in the same format as `combineTranscripts_JSON.R`: `file`, `start_time`, `end_time` (milliseconds from the start of the chunk), `text`. |
| `<recording>_cry_tv.csv` | Cry and TV detection, one row per second. |
| `<recording>_its.csv` | LENA's segments and 5-minute blocks from the `.its` file. |

`copy_results_to_lab_server.sh` copies the whole `<ID>_output` folder to the
lab server, into `SERVER_TXT/<ID>/` (set in `config.sh`).

### The cry and TV CSV

One row per second of the recording:

| Column | Meaning |
|---|---|
| `second` | Seconds from the start of the recording. |
| `cry` | 1 if `baby_cry` is at least `CRY_THRESHOLD` (0.5), otherwise 0. |
| `tv` | 1 if `television` or `radio` is at least `TV_THRESHOLD` (0.5), otherwise 0. |
| `baby_cry`, `crying_sobbing`, `whimper`, `television`, `radio` | YAMNet's score for that sound, from 0 to 1. |

The thresholds are set in `config.sh`. Because every score is kept, you can
apply a different threshold later in R, for example
`mutate(cry = baby_cry >= 0.3)`, without rerunning anything.

### The combined CSV

Each row is one stretch of time from one source, sorted by start time. All
times are seconds from the start of the recording. Columns that don't apply
to a row are empty.

| `source` | One row per |
|---|---|
| `whisper` | Whisper segment: a phrase of transcript. |
| `lena_segment` | LENA segment, with LENA's speaker label. |
| `lena_block` | LENA 5-minute block, with LENA's totals for it. |
| `cry` | Stretch of seconds marked as crying. |
| `tv` | Stretch of seconds marked as TV or radio. |

| Column | Rows | Meaning |
|---|---|---|
| `participant_id` | all | The recording, for example `1212_029787`. |
| `source` | all | See above. |
| `start_sec`, `end_sec` | all | Seconds from the start of the recording. |
| `clock_start`, `clock_end` | all | Wall-clock time, from the `.its` file. |
| `lena_block` | all | The LENA 5-minute block the row starts in, counting from 1. |
| `text` | `whisper` | What Whisper transcribed. |
| `whisper_chunk` | `whisper` | The chunk number, as in its JSON file's name. |
| `speaker` | `lena_segment` | LENA's label: `CHN` key child, `FAN` female adult, `MAN` male adult, `CXN` other child, `OLN` overlap, `TVN` TV or electronic sound, `NON` noise, `SIL` silence. Ending in `F` (`FAF`, `CHF`, ...) means faint or far. |
| `lena_conversation` | `lena_segment` | The `.its` conversation number. |
| `adult_words` | `lena_segment`, `lena_block` | LENA's adult word count. |
| `child_utterances`, `child_utterance_sec` | `lena_segment`, `lena_block` | LENA's key child utterances: count and seconds. |
| `child_cry_vfx_sec` | `lena_segment`, `lena_block` | Seconds of key child crying and vegetative sounds, by LENA. |
| `conversational_turns` | `lena_block` | LENA's conversational turn count. |
| `average_db`, `peak_db` | `lena_segment`, `lena_block` | Sound level, from LENA. |
| `cry_sec`, `tv_sec` | other sources | Seconds of the row marked as crying, or as TV. |
| `cry_score`, `tv_score` | all | The highest crying score, or TV/radio score, during the row. |
| `lena_speakers` | all but `lena_segment` | LENA's labels during the row, with seconds, most first: `SIL 3.48; CHN 1.70`. |

For example, in R, what was said while the baby cried:

```r
library(tidyverse)
combined <- read_csv("1212_029787_combined.csv")
combined %>% filter(source == "whisper", cry_sec > 0) %>% select(clock_start, text, lena_speakers)
```

### How chunks line up

Whisper transcribes each recording in chunks. If the `.its` file was on
ACCRE when transcription started, the chunks follow LENA's 5-minute blocks,
which follow the wall clock, so the first chunk is shorter than 5 minutes.
Otherwise the chunks are 5 minutes from the start of the file. Each
recording's transcript folder has a `<ID>_chunks.csv` that lists where each
chunk starts, and the combine step uses it, so it handles both kinds of
chunking. Transcripts from before that file existed are treated as 5-minute
chunks.

### Combine files somewhere else

`combineTranscripts.py` needs only Python 3.9 or newer, so you can run it on
your own computer too:

```bash
python3 combineTranscripts.py 1243_029768 \
    --transcripts "<folder with the JSON files>" \
    --cry 1243_029768_cry.csv --its 20211105_123641_029768.its \
    --out 1243_029768_combined.csv
```

Add `--no-cry` or `--no-its` to leave a source out. Run
`python3 combineTranscripts.py --help` for all options.

## Troubleshooting

| What you see | Fix |
|---|---|
| `Invalid account or account/partition combination` | Ask the lab to have ACCRE add you to `l3_humphreys_lab_iacc` and `l3_humphreys_lab`. |
| `status.sh` shows `no recording` | Copy the recording (step 3). Its file name must start with the ID, for example `1006_029795.wav`. |
| A job waits with `QOSMaxGRESPerUser` or `QOSGrpGRES` | Wait; the GPUs are in use. |
| A log ends with `CANCELLED ... DUE TO TIME LIMIT` | Expected. Run `submit_whisper_subjects.sh` again. |
| `print_its_commands.sh` says `no row for ... in the lookup table` | The child has no `.its` file at that age in `its_identifier_file_babies_crb.csv`. Check `TIMEPOINT` in `config.sh`, or update the lookup table. |
| The Whisper log says `No .its file to line the chunks up with` | The `.its` file wasn't on ACCRE, so the recording got 5-minute chunks. That still works. To line them up instead, copy the `.its` file and delete the recording's folders in `chunkedAudioInput` and `<ID>_output/transcriptOut` before transcribing. |
| `cry_status.sh` shows `no TV yet: rerun` | The cry CSV is from before TV detection. Run `submit_cry_subjects.sh`. |
| `waiting for Whisper` or `waiting for cry and TV detection` | Finish that step, and run `combine_subjects.sh` again. |
| `the lookup table names ... but it isn't in` | Copy the `.its` file (step 3). |
| `2 .its files match` | Copy the right one to `itsFiles/<ID>.its`, for example `cp itsFiles/20200214_091010_029787.its itsFiles/1024_029787.its`. |
| `Whisper chunks have no transcript` | Run `submit_whisper_subjects.sh` until `status.sh` shows `done`. |
| `Batch script contains DOS line breaks` | On ACCRE, run `sed -i 's/\r$//' ~/lena-whisper/*.sh`. |
| Errors that mention `whisper-env` or `cry-env` after the folder moved | Delete both folders and run `setup.sh` again. |

## For maintainers

All lab-wide settings are in `config.sh`: the age being processed
(`TIMEPOINT`), the lab server folders, the SLURM accounts and limits, the
Whisper model, and the cry and TV thresholds. To process another age, change
`TIMEPOINT`. When the lab gets a `batch_gpu` account, change the GPU settings
as `config.sh` describes.

The `.its` lookup table, `its_identifier_file_babies_crb.csv`, is in the
repository. Replace it with a newer export when recordings are added.

| File | Purpose |
|---|---|
| `setup.sh` | One-time setup for each user. |
| `print_wav_commands.sh`, `print_its_commands.sh` | Print commands that copy recordings and `.its` files to ACCRE. |
| `copy_results_to_lab_server.sh` | Prints commands that copy results to the lab server. |
| `submit_whisper_subjects.sh`, `run_whisper_subject.sh`, `batchWhisper.py` | Chunk and transcribe recordings on GPUs. |
| `submit_cry_subjects.sh`, `run_cry_subject.sh`, `batchCryDetection.py` | Cry and TV detection with YAMNet on CPUs. |
| `status.sh`, `cry_status.sh` | Show progress. |
| `combine_subjects.sh`, `combineTranscripts.py` | Make the combined CSV and the per-source CSVs. |
| `cleanup.sh` | Delete finished participants' files. |
| `config.sh`, `lib.sh` | Settings and shared helpers. |
| `cry_model/` | YAMNet and its license. |

`participant_ids.txt`, `my_commands.txt`, `logs/`, `runs/`, and the Python
environments are per user; `.gitignore` keeps them out of the repository.
