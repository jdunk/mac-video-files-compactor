# mac-video-files-compactor

Shell commands for inspecting, compressing, splicing, and concatenating video
files on macOS.

The public commands are intentionally short:

- `video-info`
- `video-compact`
- `video-splice`
- `video-concat`

Compression is powered by FFmpeg. Precise, no-reencode splicing and
concatenation use Apple's AVFoundation through the included Swift helpers.

## Requirements

- macOS 14 or newer
- Bash or zsh
- FFmpeg and FFprobe
- The Swift toolchain

Install FFmpeg with Homebrew:

```bash
brew install ffmpeg
```

If `swift` is unavailable, install Apple's Command Line Tools:

```bash
xcode-select --install
```

macOS 14 or newer is required because compression uses the system
`/usr/bin/trash` command to preserve replaced originals in Trash.

## Setup

Source the shell library:

```bash
source /PATH/TO/mac-video-files-compactor/mac-video-files-compactor.sh
```

Replace `/PATH/TO` with the actual parent directory where the repository is stored.
To load the commands automatically, add the resulting `source` command to
`~/.bashrc` or `~/.zshrc`.

The file must be sourced rather than executed because it defines functions and
aliases in the current shell.

## Command summary

| Command | Purpose |
| --- | --- |
| `video-info FILE` | Inspect a video and assess its compression |
| `video-compact FILE` | Compress with hardware HEVC |
| `video-compact DIR` | Compress eligible MOV/MP4 files in a directory |
| `video-compact-medium FILE` | Compress with x264's `medium` preset |
| `video-compact-slow FILE` | Compress with x264's `slow` preset |
| `video-splice FILE CUT...` | Remove one or more precise time ranges |
| `video-splice open` | Open the most recently created spliced file |
| `video-splice save` | Promote the most recently created spliced file |
| `video-concat FILE1 FILE2...` | Concatenate videos without re-encoding |

Compatibility aliases:

```text
video-compactor -> video-compact
video-splicer   -> video-splice
```

## Inspect a video

```bash
video-info recording.mov
```

Example output:

```text
recording.mov
  Size:        134.6 MB
  Duration:    00:30:00
  Codec:       hevc
  Resolution:  1920x1080
  Frame rate:  30.00 fps
  Bitrate:     0.60 Mbps
  Assessment:  OK
```

The bitrate is the whole-file average, including audio and container overhead.

Assessment rules:

| Condition | Assessment |
| --- | --- |
| Frame rate greater than 30 fps | `INEFFICIENT (fps > 30)` |
| Bitrate at least 15 Mbps | `INEFFICIENT (high bitrate)` |
| Bitrate from 8 Mbps up to 15 Mbps | `REVIEW` |
| Otherwise | `OK` |

## Compress a single video

Hardware HEVC, also available as `video-compact-hvc`:

```bash
video-compact recording.mov
```

x264 alternatives:

```bash
video-compact-medium recording.mov
video-compact-slow recording.mov
```

All compression modes:

- Produce 30 fps video.
- Convert audio to AAC at 160 kbps.
- Preserve the original filename.
- Show live percentage, processing speed, and ETA.
- Report original size, new size, and disk space saved.

Encoder settings:

| Command | Video encoder |
| --- | --- |
| `video-compact` / `video-compact-hvc` | `hevc_videotoolbox -q:v 60` |
| `video-compact-medium` | `libx264 -preset medium -crf 23` |
| `video-compact-slow` | `libx264 -preset slow -crf 23` |

### Replacement safety

Compression is an in-place operation:

1. FFmpeg writes a hidden temporary file beside the original.
2. The encode must finish successfully and produce a nonempty file.
3. The command checks whether another process still has the original open.
4. The original is moved to macOS Trash.
5. The compressed file is renamed to the original path.

If encoding or trashing fails, the original remains untouched. A completed or
partial temporary encode may remain beside it and will be overwritten on the
next attempt.

## Compress a directory

Pass a directory instead of a file:

```bash
video-compact /path/to/videos
video-compact-medium /path/to/videos
video-compact-slow /path/to/videos
```

Directory mode:

- Scans only the immediate directory; it is not recursive.
- Includes `.mov` and `.mp4` files case-insensitively.
- Sorts by file size, largest first.
- Runs `video-info` before each file.
- Skips files assessed as `OK`.
- Continues after individual failures.
- Pauses for three seconds after a failure so Ctrl-C can stop the batch.
- Displays compressed, skipped, failed, done, and remaining counts.

Use smallest-first order with either option position:

```bash
video-compact-medium --smallest-first /path/to/videos
video-compact-medium /path/to/videos --smallest-first
video-compact-medium --reverse /path/to/videos
video-compact-medium /path/to/videos --reverse
```

The queue exists only in memory. Restarting the command rescans and resorts the
directory; already-compressed files should be skipped when they assess as `OK`.

## Splice a video

`video-splice` removes the specified ranges and saves a new file with
`-spliced` before the extension:

```bash
video-splice recording.mov 70.3,90
```

Output:

```text
recording-spliced.mov
```

Times may be written as seconds, `MM:SS`, or `HH:MM:SS`, with fractional
seconds:

```bash
video-splice recording.mov 70.3,90
video-splice recording.mov 1:10.3,1:30
video-splice recording.mov 00:01:10.3,00:01:30
```

Remove multiple ordered, non-overlapping ranges in one operation:

```bash
video-splice recording.mov 70.3,90 2:07,150
```

The final end time may be omitted to remove everything from that point through
the end:

```bash
video-splice recording.mov 3:20
video-splice recording.mov 3:20,
```

A start time of zero is valid:

```bash
video-splice recording.mov 0,10.5
```

Splicing uses AVFoundation passthrough. It preserves the compressed media
instead of re-encoding the entire video, so it normally runs near file-copy
speed without generation loss. It supports `.mov` and `.mp4`.

An existing `-spliced` output is overwritten. The source remains untouched
until `save` is used.

### Open or save the latest splice

The most recently created spliced path is remembered at:

```text
~/Library/Application Support/mac-video-files-compactor/last-spliced
```

Open it in the default macOS application:

```bash
video-splice open
```

Promote it to the original filename:

```bash
video-splice save
```

You may also specify the spliced or original-looking path:

```bash
video-splice recording-spliced.mov save
video-splice recording.mov save
```

Both forms select `recording-spliced.mov` and rename it to `recording.mov`.
The `-spliced` file must exist.

**Unlike compression, splice save does not move the existing original to
Trash. It overwrites the original directly.**

Any successful save clears the remembered splice state.

Override the state directory when needed:

```bash
export VIDEO_FILES_COMPACTOR_STATE_DIR=/another/state/directory
```

## Concatenate videos

```bash
video-concat first.mov second.mov
video-concat first.mov second.mov third.mov
```

The output is named from the first input:

```text
first-concatenated.mov
```

Concatenation uses AVFoundation passthrough:

- No video or audio re-encoding.
- Native frame cadence is preserved, including mixed 30/60 fps inputs.
- Source files remain untouched.
- An existing `-concatenated` output is overwritten.

The inputs are assumed to have passthrough-compatible video and audio tracks.
The command fails rather than falling back to re-encoding.

## Notes

- Quote paths containing spaces.
- Compression is recoverable through Trash; splice save is a direct overwrite.
- Stop an active encode or batch with Ctrl-C.
- FFmpeg stdin commands are disabled so terminal keystrokes cannot accidentally
  enter FFmpeg's interactive command mode.
