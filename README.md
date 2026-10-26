# LENA Whisper transcription on ACCRE

These scripts process SEA Lab LENA recordings on ACCRE. For each recording
they:

1. Transcribe it with Whisper (`large-v2`) on ACCRE's GPUs.
2. Score every second of it for infant crying with YAMNet, Google's sound
   classifier, on ACCRE's CPUs.
3. Combine the transcript, the crying, and the LENA `.its` data into one CSV
   that puts everything on a single timeline.

They replace the *Piecemeal LENA Audio Processing* instructions and
`combineTranscripts_JSON.R`. You don't edit any file paths: setup reads your
VUNetID from your ACCRE login.

This guide is for SEA Lab members with an ACCRE account.

## Before you start

You need the following:

- An ACCRE account in the lab's group. To check, log in to ACCRE and run
  `slurm_resources`; the output should list `l3_humphreys_lab_iacc` (GPU
  jobs) and `l3_humphreys_lab` (CPU jobs).
- Edit access to the
  [LENA Transcription Tracker](https://docs.google.com/spreadsheets/d/1yqIpogNROzr-JfZtk5D6msxbtlnufOJ4n0m8fmIYhx4/edit).
- Access to the lab server, through the GlobalProtect VPN, including the
  folder with the recordings' `.its` files.
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

Setup asks you to confirm your VUNetID, then does the following:

- Checks that you can use the lab's GPU and CPU accounts.
- Creates your folders in `/nobackup/userspace/<VUNetID>/`: `rawAudio`,
  `chunkedAudioInput`, `transcriptOut`, `cryOut`, `itsFiles`, and
  `combinedOut`. Only you can open them.
- Installs Whisper in `~/lena-whisper/whisper-env`. This step takes 10–20
  minutes.
- Downloads the Whisper model (about 3 GB).
- Installs TensorFlow for cry detection in `~/lena-whisper/cry-env` (about
  1 GB), and checks that YAMNet, which comes with this repository, loads.
- Writes `~/lena-whisper/my_commands.txt`: the copy commands from this README
  with your VUNetID already filled in.

You can run setup again at any time. It skips steps that are already done.

## Process a recording

Follow these steps for each recording:

1. In the LENA Transcription Tracker, find the next recording and set it to
   **In Progress**, so nobody else picks it up.
2. Copy the recording from the lab server to ACCRE. See
   [Copy files between your computer and ACCRE](#copy-files-between-your-computer-and-accre).
3. On ACCRE, add the participant ID to your list, one ID per line (for
   example `1243_029768`):

   ```bash
   nano ~/lena-whisper/participant_ids.txt
   ```

   To save and exit nano, press Ctrl+X, then Y, then Enter. You can also
   write the list on your computer and upload it.

4. Start transcription:

   ```bash
   bash ~/lena-whisper/submit_whisper_subjects.sh
   ```

5. Start cry detection once the first transcription job has started, when
   `status.sh` shows the participant as `in progress`:

   ```bash
   bash ~/lena-whisper/submit_cry_subjects.sh
   ```

   Cry detection reads the 5-minute chunks that the first transcription job
   cuts from the recording, so it skips recordings that aren't chunked yet.
   It runs on CPUs, alongside transcription, and doesn't use your GPU time:
   one job of a few minutes per recording. See
   [How cry detection works](#how-cry-detection-works).

6. Copy the recording's `.its` file to ACCRE. See
   [Add the .its files](#add-the-its-files).
7. Check progress. Run the transcription submit script again after each
   round of jobs, until every participant shows `done`. See
   [Check progress](#check-progress).
8. Combine the results:

   ```bash
   bash ~/lena-whisper/combine_subjects.sh
   ```

   This makes one CSV per recording in
   `/nobackup/userspace/<VUNetID>/combinedOut/`. See
   [The combined CSV](#the-combined-csv).
9. Copy the transcripts, the combined CSV, and the cry detection CSV to the
   lab server. See
   [Copy files between your computer and ACCRE](#copy-files-between-your-computer-and-accre).
10. In the tracker, update **Joined?** for the recording. The combined CSV
    replaces combining the transcripts by hand.
11. Delete the participant's files from ACCRE. See [Clean up](#clean-up).

### Why you run the submit script more than once

The lab's GPU access allows each person one GPU at a time, for 30 minutes per
job. A full-day recording has about 190 five-minute chunks, and a 30-minute job
transcribes roughly 25 of them, so one recording takes about 8 jobs.

Every finished chunk is saved. When a job stops at 30 minutes, run
`submit_whisper_subjects.sh` again, and the next job continues where the last
one stopped. The script skips participants who are already done.

Cry detection doesn't have this limit: one job does a whole recording.

## Connect to the lab server

The recordings and transcripts live on the lab server. To reach it from
your computer, first connect to the GlobalProtect VPN, and then follow the
steps for your system.

**Mac:**

1. In Finder, choose **Go > Connect to Server**.
2. Enter `smb://vu1file.it.vanderbilt.edu/PBD/PSY/Humphreyslab`, and sign in
   with your VUNetID.

The server appears at `/Volumes/HumphreysLab`.

**Windows:**

1. In File Explorer, right-click **This PC** and choose **Map network drive**.
2. Choose a drive letter, for example `X:`.
3. In **Folder**, enter `\\vu1file.it.vanderbilt.edu\PBD\PSY\Humphreyslab`.
4. Clear **Reconnect at sign-in**, select **Connect using different
   credentials**, and sign in with your VUNetID.

On Windows, GlobalProtect can turn off Zscaler, and most websites then stop
loading until you disconnect. The lab server and ACCRE still work.

## Copy files between your computer and ACCRE

Run these commands on your own computer, not on ACCRE. First connect to the
lab server (see the previous section). Each `scp` command asks for your
VUNetID password.

To see these commands with your VUNetID already filled in, run
`cat ~/lena-whisper/my_commands.txt` on ACCRE.

Replace the following placeholders:

| Placeholder | Meaning | Example |
|---|---|---|
| `<VUNetID>` | Your VUNetID | `rayes2` |
| `<TIMEPOINT>` | The age folder | `12-mo` |
| `<ID4>` | The first 4 digits of the ID | `1243` |
| `<PARTICIPANT>` | The full participant ID | `1243_029768` |
| `<ITS_FOLDER>` | The lab server folder with the `.its` files and the lookup table | |
| `<ITS_FILE>` | An `.its` file's name, without `.its` | `20211105_123641_029768` |

### Mac (Terminal)

Upload a recording:

```bash
scp "/Volumes/HumphreysLab/Daily_2/LENA/LENA_raw/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_Raw/<ID4>/<PARTICIPANT>.wav" <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/rawAudio/
```

Upload a participant list. Run this from the folder that contains the list:

```bash
scp participant_ids.txt <VUNetID>@login.accre.vu:lena-whisper/participant_ids.txt
```

Upload `.its` files and the lookup table. You can list several `.its` files:

```bash
scp "<ITS_FOLDER>/<ITS_FILE>.its" "<ITS_FOLDER>/its_identifier_file_babies_crb.csv" <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/itsFiles/
```

Copy one participant's transcripts, combined CSV, and cry detection CSV to the
lab server:

```bash
mkdir -p "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>"
scp -r <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/transcriptOut/<ID4>/<PARTICIPANT> "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
scp <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/combinedOut/<ID4>/<PARTICIPANT>_combined.csv "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
scp <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/cryOut/<ID4>/<PARTICIPANT>_cry.csv "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
```

### Windows (Command Prompt)

These commands assume you mapped the lab server to drive `X:`. If you chose
another letter, use it instead. Keep the quotes and forward slashes in the
`scp` paths.

Upload a recording:

```bat
scp "X:/Daily_2/LENA/LENA_raw/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_Raw/<ID4>/<PARTICIPANT>.wav" <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/rawAudio/
```

Upload a participant list. Run this from the folder that contains the list:

```bat
scp participant_ids.txt <VUNetID>@login.accre.vu:lena-whisper/participant_ids.txt
```

Upload `.its` files and the lookup table. You can list several `.its` files:

```bat
scp "<ITS_FOLDER>/<ITS_FILE>.its" "<ITS_FOLDER>/its_identifier_file_babies_crb.csv" <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/itsFiles/
```

Copy one participant's transcripts, combined CSV, and cry detection CSV to the
lab server. The `mkdir` command creates the `<ID4>` folder; if it already
exists, `mkdir` says so, and you can ignore that message.

```bat
mkdir "X:\Daily_2\LENA\LENA_transcripts\BABIES_CRB\<TIMEPOINT>_BABIES_LENA_transcripts\<ID4>"
scp -r <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/transcriptOut/<ID4>/<PARTICIPANT> "X:/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
scp <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/combinedOut/<ID4>/<PARTICIPANT>_combined.csv "X:/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
scp <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/cryOut/<ID4>/<PARTICIPANT>_cry.csv "X:/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
```

A participant list written in Notepad works as is. The scripts ignore Windows
line endings, blank lines, and a trailing `.wav` on an ID.

The cry detection CSV keeps YAMNet's scores for every second, so with it you
can try another threshold later without running cry detection again.

## Check progress

On ACCRE, run the following commands:

```bash
bash ~/lena-whisper/status.sh       # transcription
bash ~/lena-whisper/cry_status.sh   # cry detection
```

Each lists the participants and any of its jobs in the queue:

```
PARTICIPANT      STATUS         CHUNKS TRANSCRIBED
1212_029759      in progress    48 / 192
1243_029768      not started    -
```

```
PARTICIPANT      CRY DETECTION        CRYING DETECTED
1212_029759      done                 43.9 min of 16.0 h
1243_029768      waiting for chunks   -
```

The following commands give more detail:

| Command | Shows |
|---|---|
| `squeue --me -r` | Your jobs. `R` means running; `PD` means waiting. |
| `ls -t ~/lena-whisper/logs \| head` | The newest job logs. |
| `tail -F ~/lena-whisper/logs/<log file>` | A log as it updates. Press Ctrl+C to stop watching; the job keeps running. |

## How cry detection works

`batchCryDetection.py` runs [YAMNet](https://www.kaggle.com/models/google/yamnet),
Google's sound event classifier, on each recording. YAMNet was trained on
AudioSet, a large set of labeled YouTube sound clips, and scores 521 kinds of
sound, one of which is "Baby cry, infant cry". It comes with this repository,
in `cry_model/yamnet`, so setup doesn't download it.

- **Input.** It reads the 5-minute chunks that Whisper transcribes, one at a
  time, so both use the same audio.
- **Windows.** YAMNet scores 0.96-second windows that start every 0.48
  seconds, on one grid across the whole recording, so where the chunks start
  doesn't change any score.
- **Seconds.** Each second gets the highest score among the windows centred in
  it, and counts as crying when its "Baby cry, infant cry" score is at least
  the threshold: 0.5, set by `CRY_THRESHOLD` in `config.sh`.

The output, `cryOut/<ID4>/<PARTICIPANT>_cry.csv`, has one row per second:

| Column | Meaning |
|---|---|
| `second` | Seconds from the start of the recording. |
| `cry` | 1 if `baby_cry` is at least the threshold, otherwise 0. |
| `baby_cry` | YAMNet's score for "Baby cry, infant cry", from 0 to 1. |
| `crying_sobbing` | Its score for "Crying, sobbing", which covers crying at any age. |
| `whimper` | Its score for "Whimper". |

YAMNet hasn't been validated on LENA recordings, which are long, noisy, and
recorded from a vest pocket, so treat the threshold as a starting point.
Before you rely on it, compare `cry` with hand-coded crying in a few
recordings, and adjust the threshold if needed. The cry CSV keeps every
second's score, so you can apply a new threshold to finished recordings in R,
for example `mutate(cry = baby_cry >= 0.3)`, without running cry detection
again. In the combined CSV, `cry_score` doesn't depend on the threshold
either.

As a rough check, 40 crying clips from the public
[ESC-50](https://github.com/karolpiczak/ESC-50) dataset were mixed into 25
minutes of background noise at 30–100% volume, with 60 clips of other sounds
(laughing, coughing, animals, household noise). With the 0.5 threshold,
cry detection flagged 33 of the 40 crying clips, covering 46% of their
seconds (the clips include pauses), and 1 of the 1,300 other seconds; none of
the other clips set it off. With 0.3, it flagged 58% of the crying seconds and
3 others. Real recordings are harder than this test.

## Add the .its files

The combined CSV takes LENA's segments, speaker labels, and 5-minute blocks
from the recording's `.its` file. Copy the `.its` file to
`/nobackup/userspace/<VUNetID>/itsFiles/`, together with the lookup table
`its_identifier_file_babies_crb.csv` (once). See
[Copy files between your computer and ACCRE](#copy-files-between-your-computer-and-accre).

`.its` files are named after when they were transferred, for example
`20201103_103018_029787.its`, so `combine_subjects.sh` uses the lookup table
to find each participant's file. For `1212_029787`, it looks for the row
whose `ExternalReferenceID` starts with `1212` and whose `ITS_File_Name`
ends with `029787` (the recorder):

```
ExternalReferenceID,RecordingDate,ITS_File_Name
1212_6mo,10/26/20,20201103_103018_029787
```

Any CSV in `itsFiles` with `ExternalReferenceID` and `ITS_File_Name` columns
counts as a lookup table, so other studies' tables work too.

Sometimes the same child wore the same recorder at two ages, so two `.its`
files match. If both are in `itsFiles`, `combine_subjects.sh` lists them and
stops for that participant. Copy the right one to a file named after the
participant, and run it again. A file named `<PARTICIPANT>.its` is always used
first. For example:

```bash
cp /nobackup/userspace/$USER/itsFiles/20200214_091010_029787.its /nobackup/userspace/$USER/itsFiles/1024_029787.its
```

You can leave many `.its` files in `itsFiles`; cleanup doesn't delete them.

## The combined CSV

`combine_subjects.sh` writes one CSV per recording:
`/nobackup/userspace/<VUNetID>/combinedOut/<ID4>/<PARTICIPANT>_combined.csv`.
It combines only participants whose transcription and cry detection are done,
and it lists the others with the reason. To redo a participant, add
`--overwrite`.

Each row is one stretch of time from one source, and the rows are sorted by
start time. The `source` column says which kind of row it is:

| `source` | One row per |
|---|---|
| `whisper` | Whisper segment: a sentence or phrase of transcript. |
| `lena_segment` | LENA segment, with LENA's speaker label. A 16-hour recording has about 30,000. |
| `lena_block` | LENA 5-minute block, with LENA's totals for it. |
| `cry` | Stretch of seconds that cry detection marks as crying (see [How cry detection works](#how-cry-detection-works)). |

### How the times line up

All times are on one timeline: `start_sec` and `end_sec` are seconds from the
start of the recording, which is the same moment in the `.wav` file, the
`.its` file, and cry detection.

- **Whisper.** The recording is cut into 5-minute chunks from the start of the
  file, so chunk 12 covers seconds 3600–3900. Whisper's times count from the
  start of each chunk, and the combined CSV adds the chunk's start to them.
- **Clock time.** The `.its` file records when the recording started, so every
  row also has a wall-clock time, in the time zone in the `.its` file
  (`America/Chicago`), with daylight saving time.
- **LENA's 5-minute blocks** follow the wall clock instead of the start of the
  file. If a recording starts at 10:48, block 1 is the 2 minutes until 10:50,
  every later block is 5 minutes, and the last block is usually short too. So
  a Whisper chunk usually spans parts of two LENA blocks; `lena_block` tells
  you which block each row starts in.

Whisper pads the end of each chunk with silence and sometimes makes up text
there, such as "Music" or one word repeated every few seconds, with times
after the end of the chunk. Those segments would land on top of the next
chunk, so the combined CSV leaves them out, and cuts segments that run past
the end of their chunk. Otherwise the transcript rows are the same as
`combineTranscripts_JSON.R` produced.

### Columns

Columns that don't apply to a row are empty.

| Column | Rows | Meaning |
|---|---|---|
| `participant_id` | all | For example `1212_029787`. |
| `source` | all | `whisper`, `lena_segment`, `lena_block`, or `cry` (see above). |
| `start_sec`, `end_sec` | all | Seconds from the start of the recording. |
| `clock_start`, `clock_end` | all | Wall-clock time, for example `2020-10-26 06:58:41.00`. |
| `lena_block` | all | The LENA 5-minute block that the row starts in, counting from 1. |
| `text` | `whisper` | What Whisper transcribed. |
| `whisper_chunk` | `whisper` | The chunk's number, as in its JSON file's name. |
| `avg_logprob`, `no_speech_prob`, `compression_ratio` | `whisper` | Whisper's measures of how sure it is. Whisper itself treats a stretch as silence when `no_speech_prob` is above 0.6 and `avg_logprob` is below -1, and a `compression_ratio` above 2.4 means repeated text. |
| `speaker` | `lena_segment` | LENA's label: `CHN` key child, `FAN` female adult, `MAN` male adult, `CXN` other child, `OLN` overlapping sound, `TVN` TV or electronic sound, `NON` noise, `SIL` silence. A label ending in `F` instead of `N` (`FAF`, `CHF`, ...) is faint or far away. |
| `lena_conversation` | `lena_segment` | The `.its` conversation number, for segments that are part of a conversation. |
| `adult_words` | `lena_segment`, `lena_block` | LENA's adult word count. |
| `child_utterances` | `lena_segment`, `lena_block` | LENA's count of key child utterances. |
| `child_utterance_sec` | `lena_segment`, `lena_block` | Seconds of key child utterances. |
| `child_cry_vfx_sec` | `lena_segment`, `lena_block` | Seconds of key child crying and vegetative sounds, by LENA's measure. |
| `conversational_turns` | `lena_block` | LENA's conversational turn count. |
| `average_db`, `peak_db` | `lena_segment`, `lena_block` | Sound level, as LENA reports it. |
| `cry_sec` | `whisper`, `lena_segment`, `lena_block` | Seconds of the row that cry detection marks as crying. |
| `cry_score` | all | The highest YAMNet "Baby cry, infant cry" score during the row, from 0 to 1. Unlike `cry_sec`, it doesn't depend on the threshold. |
| `lena_speakers` | `whisper`, `lena_block`, `cry` | LENA's labels during the row, with seconds, most first: `SIL 3.48; CHN 1.70`. |

For example, in R, the transcript said while the baby cried, with who LENA
thinks was speaking:

```r
library(tidyverse)
combined <- read_csv("1212_029787_combined.csv")
combined %>% filter(source == "whisper", cry_sec > 0) %>% select(clock_start, text, lena_speakers)
```

### Combine files somewhere else

`combineTranscripts.py` needs Python 3.9 or newer and no other packages, so
you can also run it on your own computer, for example on transcripts that are
already on the lab server. Name each file:

```bash
python3 combineTranscripts.py 1243_029768 \
    --transcripts "<folder with the JSON files>" \
    --cry 1243_029768_cry.csv --its 20211105_123641_029768.its \
    --out 1243_029768_combined.csv
```

Add `--no-cry` or `--no-its` to leave a source out; with both, you get only
the transcript, like `combineTranscripts_JSON.R`. Without `--out`, the CSV goes
next to the JSON folder. Run `python3 combineTranscripts.py --help` for all
options.

The script stops for a participant if the sources don't fit together: if
transcript chunks are missing, if cry detection and the `.its` file cover
different lengths, or if the `.its` file is from a different recorder than the
participant ID. Add `--skip-checks` to write the CSV anyway.

## Clean up

ACCRE doesn't back up `/nobackup`, so delete a participant's files only after
the transcripts and combined CSV are on the lab server. On ACCRE, run the
following command with one or more participant IDs:

```bash
bash ~/lena-whisper/cleanup.sh 1243_029768
```

It lists the participant's recording, chunks, transcripts, cry detection
CSV, and combined CSV with their sizes, and deletes them when you confirm.
It also removes the ID from `participant_ids.txt`. It skips a participant
whose jobs are still queued or running, and it leaves the `.its` files.

Each run also tidies up after jobs and setups that stopped partway, without
asking: unfinished output files, setup's temporary install files, and
participant lists in `runs/` that no queued job needs. To do only that, run
it without IDs.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `Invalid account or account/partition combination` | Your user isn't in the lab's GPU account (Whisper) or CPU account (cry detection). | Ask the lab to have ACCRE add you to `l3_humphreys_lab_iacc` and `l3_humphreys_lab`. |
| `status.sh` shows `no recording` | The `.wav` file isn't in `rawAudio`, or its name doesn't match the ID. | Upload the file, and check that its name is exactly `<PARTICIPANT>.wav`. |
| A job waits with `QOSMaxGRESPerUser` | You can use one GPU at a time. | Wait. It starts when your running job ends. |
| A job waits with `QOSGrpGRES` | All the shared debug GPUs are in use. | Wait. |
| A log ends with `CANCELLED ... DUE TO TIME LIMIT` | The Whisper job reached 30 minutes. This is expected. | Run `submit_whisper_subjects.sh` again. |
| A log ends with `No GPU on this node` | The script ran without a GPU. | Start jobs only with `submit_whisper_subjects.sh`. |
| `sbatch: error: Batch script contains DOS line breaks` | A script was edited on Windows. | On ACCRE, run `sed -i 's/\r$//' ~/lena-whisper/*.sh`. |
| `not chunked yet` from `submit_cry_subjects.sh` | Transcription hasn't cut that recording into chunks yet. | Run `submit_whisper_subjects.sh`, and run the cry detection submit script again once `status.sh` shows the participant `in progress`. |
| `YAMNet isn't in ...` | `cry_model/yamnet` is missing or was changed. | Restore it: `git -C ~/lena-whisper checkout -- cry_model`. |
| `cry_status.sh` shows `not started` after a job ran | The job stopped with an error. | Read the end of its log: `ls -t ~/lena-whisper/logs/cry_subject_* \| head`. |
| `waiting for Whisper` or `waiting for cry detection` | That step isn't done yet. | Finish it, and run `combine_subjects.sh` again. |
| `no row in the lookup table matches` | The lookup table isn't in `itsFiles`, or doesn't list the recording. | Upload the lookup table, or copy the `.its` file to `itsFiles/<PARTICIPANT>.its`. |
| `the lookup table names ... but it isn't in` | The recording's `.its` file isn't in `itsFiles`. | Upload it (see [Add the .its files](#add-the-its-files)). |
| `2 .its files match` | The child wore the same recorder at two ages. | Copy the right file to `<PARTICIPANT>.its` (see [Add the .its files](#add-the-its-files)). |
| `Whisper chunks have no transcript` | Transcription isn't finished, or a chunk failed. | Run `submit_whisper_subjects.sh` until `status.sh` shows `done`. |
| `the .its file is from recorder ...` | The `.its` file belongs to another recording. | Check the lookup table, and use the right `.its` file. |
| Python errors that mention `whisper-env` or `cry-env` after the repository folder moved | Python environments don't work after they're moved. | Delete both folders and run `setup.sh` again. |

## Moving from the PDF instructions or an earlier version

If you used the PDF version or an earlier version of these scripts, your
Whisper environment is in `~/whisper-env`. The scripts now keep it in
`~/lena-whisper/whisper-env`, so run `setup.sh` again: it installs Whisper
there (10–20 minutes) and reuses the downloaded model. When it's done, run
`bash ~/lena-whisper/cleanup.sh`, which offers to delete `~/whisper-env`.

Your recordings, chunks, and transcripts stay in `/nobackup`, and finished
chunks are still skipped. If you used the PDF version, move your participant
IDs into `~/lena-whisper/participant_ids.txt`. You can then delete the old
copies of the four scripts and `participant_ids.txt` from your home folder.

## Resources

The following pages explain ACCRE, the lab's process, and YAMNet in more
depth:

| Resource | What it covers |
|---|---|
| [LENA Transcription Tracker](https://docs.google.com/spreadsheets/d/1yqIpogNROzr-JfZtk5D6msxbtlnufOJ4n0m8fmIYhx4/edit) | Which recordings are claimed, transcribed, and joined. |
| [Piecemeal LENA Audio Processing](https://docs.google.com/document/d/1dcLeIcdb89ngQM-lHnrUPa7nq952yN8w5VCs7hfyV0c/edit) | The original step-by-step instructions that this README replaces. |
| [SEA Lab GitHub](https://github.com/vanderbiltsealab) | The lab's code. |
| [YAMNet](https://www.kaggle.com/models/google/yamnet) | The sound classifier that cry detection uses. |
| [YAMNet code](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet) | How YAMNet frames and scores audio, and its 521 classes. |
| [ACCRE documentation](https://help.accre.vanderbilt.edu/) | Accounts, storage, SLURM, and software on ACCRE. |
| [ACCRE SLURM examples](https://github.com/accre/SLURM) | Example job scripts from ACCRE's SLURM training. |
| [Intro to SLURM slides](https://vanderbilt.app.box.com/s/2090ueppze3s4sxs3jf86a2lzjb5enix) | How jobs, partitions, and accounts work at ACCRE. |
| [Intro to ACCRE slides](https://vanderbilt.app.box.com/s/l2uop6ebq41mthdqh31x895o9xx1uwip) | An overview of the cluster. |
| [Intro to Unix/Linux slides](https://vanderbilt.app.box.com/s/j1d815fzdvo2tmtafb4hgmc8pfymscoa) | The command-line basics these scripts assume. |
| [Software stack slides](https://vanderbilt.app.box.com/s/bl1jsbo04l8u42k12k069px3mdkx1zdz) | `setup_accre_software_stack` and `module load`. |

## For maintainers

All lab-wide settings are in `config.sh`: the SLURM accounts, partitions, GPU
type, time limits, and memory for both kinds of job, the Whisper model, and
the folders. Users don't edit any file.

The pipeline currently uses ACCRE's shared debug QoS (`debug_iacc`) for
Whisper. ACCRE describes that QoS as being for quick debugging, so it's a
stopgap. When the lab gets a `batch_gpu` account, change the settings that
`config.sh` lists in its comments. Each recording then finishes in a single
job. Cry detection uses the lab's CPU account on the `batch` partition
(`CRY_SLURM_*` in `config.sh`).

Each user's folders, including `itsFiles`, are private to them. To keep one
shared folder of `.its` files instead, set `ITS_DIR` in `config.sh` to a
folder that everyone in the lab can read.

The repository contains the following files:

| File | Purpose |
|---|---|
| `setup.sh` | One-time setup for each user. |
| `submit_whisper_subjects.sh` | Submits one GPU job per unfinished participant. |
| `run_whisper_subject.sh` | The Whisper job script. The submit script runs it. |
| `batchWhisper.py` | Chunks a recording and transcribes the chunks. |
| `status.sh` | Shows transcription progress per participant. |
| `submit_cry_subjects.sh` | Submits one CPU job per participant without cry detection. |
| `run_cry_subject.sh` | The cry detection job script. The submit script runs it. |
| `batchCryDetection.py` | Scores each second of a recording for crying with YAMNet. |
| `cry_status.sh` | Shows cry detection progress per participant. |
| `requirements-cry.txt` | The packages in the cry detection environment. |
| `cry_model/` | YAMNet, its license, and where it came from (`cry_model/README.md`). |
| `combine_subjects.sh` | Combines every participant whose steps are done. |
| `combineTranscripts.py` | Puts one recording's transcript, `.its` data, and crying on one timeline. Replaces `combineTranscripts_JSON.R`. |
| `cleanup.sh` | Deletes finished participants' files and leftovers. |
| `config.sh` | Lab-wide settings. |
| `lib.sh` | Helpers that the other scripts share. |

`participant_ids.txt`, `my_commands.txt`, `logs/`, `runs/`, and both Python
environments are per user, and `.gitignore` keeps them out of the repository. Participant IDs never reach
GitHub.

### Cry detection

YAMNet is stored in the repository (about 18 MB) rather than downloaded, so
cry detection keeps working if a download link changes. `cry_model/README.md`
says where it came from, with checksums. To change the threshold for the whole
lab, change `CRY_THRESHOLD` in `config.sh`.

ffmpeg cuts Whisper's chunks within a few hundredths of a second of every 5
minutes. If each chunk's windows started at the chunk's own start, they'd
shift slightly at every chunk, and YAMNet's score for a short sound can change
a lot with a small shift. So `batchCryDetection.py` places the windows on one
grid across the whole recording, and completes each chunk's last windows with
the start of the next chunk. In testing, this gave exactly the scores of
running YAMNet on the whole recording at once.
