# LENA Whisper transcription on ACCRE

These scripts transcribe SEA Lab LENA recordings with Whisper (`large-v2`) on
ACCRE's GPUs. They replace the *Piecemeal LENA Audio Processing* instructions.
You don't edit any file paths: setup reads your VUNetID from your ACCRE login.

This guide is for SEA Lab members with an ACCRE account. It doesn't cover
combining transcripts, which Dylan does for now.

## Before you start

You need the following:

- An ACCRE account in the lab's group. To check, log in to ACCRE and run
  `slurm_resources`; the output should list `l3_humphreys_lab_iacc`.
- Edit access to the
  [LENA Transcription Tracker](https://docs.google.com/spreadsheets/d/1yqIpogNROzr-JfZtk5D6msxbtlnufOJ4n0m8fmIYhx4/edit).
- Access to the lab server, through the GlobalProtect VPN.
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

- Checks that you can use the lab's GPU account.
- Creates your folders in `/nobackup/userspace/<VUNetID>/`: `rawAudio`,
  `chunkedAudioInput`, and `transcriptOut`. Only you can open them.
- Installs Whisper in `~/whisper-env`. This step takes 10–20 minutes.
- Downloads the Whisper model (about 3 GB).
- Writes `~/lena-whisper/my_commands.txt`: the copy commands from this README
  with your VUNetID already filled in.

You can run setup again at any time. It skips steps that are already done.

## Transcribe a recording

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

5. Check progress, and continue until every participant shows `done`. See
   [Check progress](#check-progress).
6. Copy the transcripts back to the lab server. See
   [Copy files between your computer and ACCRE](#copy-files-between-your-computer-and-accre).
7. In the tracker, set **Joined?** to **In Progress**. Dylan combines the
   transcripts.
8. Delete the participant's files from ACCRE. See
   [Clean up](#clean-up).

### Why you run the submit script more than once

The lab's GPU access allows each person one GPU at a time, for 30 minutes per
job. A full-day recording has about 190 five-minute chunks, and a 30-minute job
transcribes roughly 25 of them, so one recording takes about 8 jobs.

Every finished chunk is saved. When a job stops at 30 minutes, run
`submit_whisper_subjects.sh` again, and the next job continues where the last
one stopped. The script skips participants who are already done.

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

### Mac (Terminal)

Upload a recording:

```bash
scp "/Volumes/HumphreysLab/Daily_2/LENA/LENA_raw/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_Raw/<ID4>/<PARTICIPANT>.wav" <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/rawAudio/
```

Upload a participant list. Run this from the folder that contains the list:

```bash
scp participant_ids.txt <VUNetID>@login.accre.vu:lena-whisper/participant_ids.txt
```

Copy one participant's finished transcripts to the lab server:

```bash
mkdir -p "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>"
scp -r <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/transcriptOut/<ID4>/<PARTICIPANT> "/Volumes/HumphreysLab/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
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

Copy one participant's finished transcripts to the lab server. The `mkdir`
command creates the `<ID4>` folder; if it already exists, `mkdir` says so,
and you can ignore that message.

```bat
mkdir "X:\Daily_2\LENA\LENA_transcripts\BABIES_CRB\<TIMEPOINT>_BABIES_LENA_transcripts\<ID4>"
scp -r <VUNetID>@login.accre.vu:/nobackup/userspace/<VUNetID>/transcriptOut/<ID4>/<PARTICIPANT> "X:/Daily_2/LENA/LENA_transcripts/BABIES_CRB/<TIMEPOINT>_BABIES_LENA_transcripts/<ID4>/"
```

A participant list written in Notepad works as is. The scripts ignore Windows
line endings, blank lines, and a trailing `.wav` on an ID.

## Check progress

On ACCRE, run the following command:

```bash
bash ~/lena-whisper/status.sh
```

It lists each participant and any jobs in the queue:

```
PARTICIPANT      STATUS         CHUNKS TRANSCRIBED
1212_029759      in progress    48 / 192
1243_029768      not started    -
```

The following commands give more detail:

| Command | Shows |
|---|---|
| `squeue --me -r` | Your jobs. `R` means running; `PD` means waiting. |
| `ls -t ~/lena-whisper/logs \| head` | The newest job logs. |
| `tail -F ~/lena-whisper/logs/<log file>` | A log as it updates. Press Ctrl+C to stop watching; the job keeps running. |

## Clean up

ACCRE doesn't back up `/nobackup`, so delete a participant's files only after
the transcripts are on the lab server. On ACCRE, set `P` to the participant
ID, then delete the recording, chunks, and transcripts:

```bash
P=1243_029768
rm -f  /nobackup/userspace/$USER/rawAudio/$P.wav /nobackup/userspace/$USER/rawAudio/${P:0:4}/$P.wav
rm -rf /nobackup/userspace/$USER/chunkedAudioInput/${P:0:4}/$P
rm -rf /nobackup/userspace/$USER/transcriptOut/${P:0:4}/$P
```

Then remove the ID from `participant_ids.txt`.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `Invalid account or account/partition combination` | Your user isn't in the lab's GPU account. | Ask the lab to have ACCRE add you to `l3_humphreys_lab_iacc`. |
| `status.sh` shows `no recording` | The `.wav` file isn't in `rawAudio`, or its name doesn't match the ID. | Upload the file, and check that its name is exactly `<PARTICIPANT>.wav`. |
| A job waits with `QOSMaxGRESPerUser` | You can use one GPU at a time. | Wait. It starts when your running job ends. |
| A job waits with `QOSGrpGRES` | All the shared debug GPUs are in use. | Wait. |
| A log ends with `CANCELLED ... DUE TO TIME LIMIT` | The job reached 30 minutes. This is expected. | Run `submit_whisper_subjects.sh` again. |
| A log ends with `No GPU on this node` | The script ran without a GPU. | Start jobs only with `submit_whisper_subjects.sh`. |
| `sbatch: error: Batch script contains DOS line breaks` | A script was edited on Windows. | On ACCRE, run `sed -i 's/\r$//' ~/lena-whisper/*.sh`. |

## Moving from the PDF instructions

If you used the PDF version, setup reuses your `~/whisper-env` environment
and the downloaded model. Your recordings, chunks, and transcripts stay in
`/nobackup`, and finished chunks are still skipped. Move your participant IDs
into `~/lena-whisper/participant_ids.txt`. You can then delete the old copies
of the four scripts and `participant_ids.txt` from your home folder.

## Resources

The following pages explain ACCRE and the lab's process in more depth:

| Resource | What it covers |
|---|---|
| [LENA Transcription Tracker](https://docs.google.com/spreadsheets/d/1yqIpogNROzr-JfZtk5D6msxbtlnufOJ4n0m8fmIYhx4/edit) | Which recordings are claimed, transcribed, and joined. |
| [Piecemeal LENA Audio Processing](https://docs.google.com/document/d/1dcLeIcdb89ngQM-lHnrUPa7nq952yN8w5VCs7hfyV0c/edit) | The original step-by-step instructions that this README replaces. |
| [SEA Lab GitHub](https://github.com/vanderbiltsealab) | The lab's code. |
| [ACCRE documentation](https://help.accre.vanderbilt.edu/) | Accounts, storage, SLURM, and software on ACCRE. |
| [ACCRE SLURM examples](https://github.com/accre/SLURM) | Example job scripts from ACCRE's SLURM training. |
| [Intro to SLURM slides](https://vanderbilt.app.box.com/s/2090ueppze3s4sxs3jf86a2lzjb5enix) | How jobs, partitions, and accounts work at ACCRE. |
| [Intro to ACCRE slides](https://vanderbilt.app.box.com/s/l2uop6ebq41mthdqh31x895o9xx1uwip) | An overview of the cluster. |
| [Intro to Unix/Linux slides](https://vanderbilt.app.box.com/s/j1d815fzdvo2tmtafb4hgmc8pfymscoa) | The command-line basics these scripts assume. |
| [Software stack slides](https://vanderbilt.app.box.com/s/bl1jsbo04l8u42k12k069px3mdkx1zdz) | `setup_accre_software_stack` and `module load`. |

## For maintainers

All lab-wide settings are in `config.sh`: the SLURM account, partition, GPU
type, time limit, memory, and Whisper model. Users don't edit any file.

The pipeline currently uses ACCRE's shared debug QoS (`debug_iacc`). ACCRE
describes that QoS as being for quick debugging, so it's a stopgap. When the
lab gets a `batch_gpu` account, change the settings that `config.sh` lists
in its comments. Each recording then finishes in a single job.

The repository contains the following files:

| File | Purpose |
|---|---|
| `setup.sh` | One-time setup for each user. |
| `submit_whisper_subjects.sh` | Submits one GPU job per unfinished participant. |
| `run_whisper_subject.sh` | The job script. The submit script runs it. |
| `batchWhisper.py` | Chunks a recording and transcribes the chunks. |
| `status.sh` | Shows progress per participant. |
| `config.sh` | Lab-wide settings. |
| `lib.sh` | Helpers that the other scripts share. |

`participant_ids.txt`, `my_commands.txt`, `logs/`, and `runs/` are per user,
and `.gitignore` keeps them out of the repository. Participant IDs never
reach GitHub.
