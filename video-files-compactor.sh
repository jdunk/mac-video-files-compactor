video-info()
{
    if [ "$#" -ne 1 ]; then
        echo "Usage: video-info FILE" >&2
        return 2
    fi

    local file=$1
    local size duration codec width height fps_raw fps
    local bitrate verdict

    if [ ! -f "$file" ]; then
        echo "Not a file: $file" >&2
        return 1
    fi

    command -v ffprobe >/dev/null 2>&1 || {
        echo "ffprobe not found" >&2
        return 127
    }

    # macOS/BSD stat, with GNU fallback
    size=$(stat -f '%z' "$file" 2>/dev/null ||
           stat -c '%s' "$file" 2>/dev/null) || return 1

    duration=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=nw=1:nk=1 \
        "$file")

    codec=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1 \
        "$file")

    width=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=width \
        -of default=nw=1:nk=1 \
        "$file")

    height=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=height \
        -of default=nw=1:nk=1 \
        "$file")

    fps_raw=$(ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=avg_frame_rate \
        -of default=nw=1:nk=1 \
        "$file")

    if [ -z "$duration" ] ||
       [ "$duration" = "N/A" ] ||
       ! awk -v n="$duration" 'BEGIN { exit !(n > 0) }'
    then
        echo "Could not determine duration: $file" >&2
        return 1
    fi

    if [ -z "$codec" ]; then
        echo "No video stream found: $file" >&2
        return 1
    fi

    fps=$(awk -v rate="$fps_raw" '
        BEGIN {
            split(rate, parts, "/")

            if (parts[2] > 0)
                printf "%.2f", parts[1] / parts[2]
            else
                printf "%.2f", parts[1]
        }
    ')

    # Actual whole-file average bitrate, including any audio/container overhead.
    bitrate=$(awk -v bytes="$size" -v seconds="$duration" '
        BEGIN {
            printf "%.2f", bytes * 8 / seconds / 1000000
        }
    ')

    if awk -v fps="$fps" 'BEGIN { exit !(fps > 30) }'; then
        verdict="INEFFICIENT (fps > 30)"
    elif awk -v bitrate="$bitrate" 'BEGIN { exit !(bitrate >= 15) }'; then
        verdict="INEFFICIENT (high bitrate)"
    elif awk -v bitrate="$bitrate" 'BEGIN { exit !(bitrate >= 8) }'; then
        verdict="REVIEW"
    else
        verdict="OK"
    fi

    printf '%s\n' "$file"
    printf '  Size:        %.1f MB\n' \
        "$(awk -v bytes="$size" 'BEGIN { print bytes / 1000000 }')"
    printf '  Duration:    %02d:%02d:%02d\n' \
        "$(awk -v s="$duration" 'BEGIN { print int(s / 3600) }')" \
        "$(awk -v s="$duration" 'BEGIN { print int(s % 3600 / 60) }')" \
        "$(awk -v s="$duration" 'BEGIN { print int(s % 60) }')"
    printf '  Codec:       %s\n' "$codec"
    printf '  Resolution:  %sx%s\n' "$width" "$height"
    printf '  Frame rate:  %s fps\n' "$fps"
    printf '  Bitrate:     %s Mbps\n' "$bitrate"
    printf '  Assessment:  %s\n' "$verdict"
}

_video_compact_check()
{
    if [ "$#" -ne 2 ]; then
        echo "Usage: $1 FILE" >&2
        return 2
    fi

    if [ ! -f "$2" ]; then
        echo "Not a file: $2" >&2
        return 1
    fi

    command -v ffmpeg >/dev/null 2>&1 || {
        echo "ffmpeg not found" >&2
        return 127
    }
}

_video_compact_trash()
{
    if ! command -v trash >/dev/null 2>&1; then
        echo "The macOS 'trash' command was not found (requires macOS 14+)." >&2
        return 127
    fi

    trash --stopOnError "$1"
}

_video_compact_report_open_handles()
{
    local file=$1
    local handles

    command -v lsof >/dev/null 2>&1 || return 1
    handles=$(lsof -nP "$file" 2>/dev/null) || return 1

    [ -n "$handles" ] || return 1

    echo "Cannot replace the original because it is open in:" >&2
    printf '%s\n' "$handles" >&2
    echo "Close those processes, then run the command again." >&2
    return 0
}

_video_compact_replace()
{
    local command_name=$1
    local input=$2
    shift 2

    _video_compact_check "$command_name" "$input" || return

    local absolute_input directory filename stem extension temp
    local original_size new_size saved

    directory=$(cd "$(dirname "$input")" && pwd -P) || return 1
    filename=${input##*/}
    absolute_input=$directory/$filename

    case $filename in
        *.*)
            stem=${filename%.*}
            extension=.${filename##*.}
            ;;
        *)
            stem=$filename
            extension=.mp4
            ;;
    esac

    temp=$directory/.$stem.video-compact.tmp$extension

    original_size=$(stat -f '%z' "$absolute_input" 2>/dev/null ||
                    stat -c '%s' "$absolute_input" 2>/dev/null) || return 1

    if ! ffmpeg -y -i "$absolute_input" \
        -map 0:v:0 -map '0:a?' -map_metadata 0 \
        -vf fps=30 \
        "$@" \
        -c:a aac -b:a 160k \
        -movflags +faststart \
        "$temp"
    then
        echo "Compression failed; original left untouched: $absolute_input" >&2
        return 1
    fi

    if [ ! -s "$temp" ]; then
        echo "Compression produced no usable file; original left untouched." >&2
        return 1
    fi

    new_size=$(stat -f '%z' "$temp" 2>/dev/null ||
               stat -c '%s' "$temp" 2>/dev/null) || return 1

    if _video_compact_report_open_handles "$absolute_input"; then
        echo "Original left untouched: $absolute_input" >&2
        echo "Completed compressed file: $temp" >&2
        return 1
    fi

    if ! _video_compact_trash "$absolute_input"; then
        echo "Could not move original to Trash." >&2
        echo "Original left untouched: $absolute_input" >&2
        echo "Completed compressed file: $temp" >&2
        return 1
    fi

    if ! mv "$temp" "$absolute_input"; then
        echo "Could not rename compressed file; original is in Trash." >&2
        echo "Compressed file remains at: $temp" >&2
        return 1
    fi

    saved=$((original_size - new_size))

    awk -v original="$original_size" -v new="$new_size" -v saved="$saved" '
        BEGIN {
            printf "Original size:  %.2f MB\n", original / 1000000
            printf "New size:       %.2f MB\n", new / 1000000
            printf "Disk space saved: %.2f MB (%.1f%%)\n", \
                saved / 1000000, saved * 100 / original
        }
    '
}

video-compact-hvc()
{
    if [ "$#" -ne 1 ]; then
        echo "Usage: video-compact-hvc FILE" >&2
        return 2
    fi

    _video_compact_replace "video-compact-hvc" "$@" \
        -c:v hevc_videotoolbox -q:v 60 -tag:v hvc1
}

video-compact-slow()
{
    if [ "$#" -ne 1 ]; then
        echo "Usage: video-compact-slow FILE" >&2
        return 2
    fi

    _video_compact_replace "video-compact-slow" "$@" \
        -c:v libx264 -preset slow -crf 23
}

video-compact-medium()
{
    if [ "$#" -ne 1 ]; then
        echo "Usage: video-compact-medium FILE" >&2
        return 2
    fi

    _video_compact_replace "video-compact-medium" "$@" \
        -c:v libx264 -preset medium -crf 23
}

alias video-compact='video-compact-hvc'

if [ -n "${BASH_VERSION:-}" ]; then
    _video_files_compactor_source=${BASH_SOURCE[0]}
else
    _video_files_compactor_source=$0
fi

_video_files_compactor_dir=$(
    cd "$(dirname "$_video_files_compactor_source")" && pwd -P
)

_video_splicer_state_file()
{
    local state_dir

    state_dir=${VIDEO_FILES_COMPACTOR_STATE_DIR:-"$HOME/Library/Application Support/video-files-compactor"}
    mkdir -p "$state_dir" || return 1
    printf '%s/last-spliced\n' "$state_dir"
}

_video_splicer_save()
{
    local input=$1
    local state_file=$2
    local stem extension original

    if [ ! -f "$input" ]; then
        echo "Not a file: $input" >&2
        return 1
    fi

    case $input in
        *-spliced.mov|*-spliced.mp4|*-spliced.MOV|*-spliced.MP4)
            ;;
        *)
            echo "Refusing to save: filename must end in -spliced.mov or -spliced.mp4" >&2
            return 2
            ;;
    esac

    stem=${input%.*}
    extension=${input##*.}
    original=${stem%-spliced}.$extension

    command mv -f "$input" "$original" || return 1
    printf '%s\n' "$original"

    if [ -n "$state_file" ]; then
        : > "$state_file"
    fi
}

video-splicer()
{
    local module_cache state_file input output status

    if [ "$#" -eq 1 ] && [ "$1" = "save" ]; then
        state_file=$(_video_splicer_state_file) || return 1

        if [ ! -s "$state_file" ]; then
            echo "No recently spliced file is waiting to be saved." >&2
            return 1
        fi

        IFS= read -r input < "$state_file"
        _video_splicer_save "$input" "$state_file"
        return
    fi

    if [ "$#" -eq 2 ] && [ "$2" = "save" ]; then
        state_file=$(_video_splicer_state_file) || return 1
        _video_splicer_save "$1" "$state_file"
        return
    fi

    if [ "$#" -lt 2 ]; then
        echo "Usage: video-splicer FILENAME START,END [START,END ...] [FINAL_START]" >&2
        echo "       video-splicer save" >&2
        echo "       video-splicer FILENAME-spliced.mov save" >&2
        return 2
    fi

    command -v swift >/dev/null 2>&1 || {
        echo "swift not found" >&2
        return 127
    }

    module_cache=${TMPDIR:-/tmp}/video-splicer-module-cache
    mkdir -p "$module_cache" || return 1

    output=$(
        swift -module-cache-path "$module_cache" \
            "$_video_files_compactor_dir/video-splicer.swift" "$@"
    )
    status=$?
    printf '%s\n' "$output"

    if [ "$status" -ne 0 ]; then
        return "$status"
    fi

    input=${output%%$'\n'*}
    state_file=$(_video_splicer_state_file) || return 1
    printf '%s\n' "$input" > "$state_file"
}

video-concat()
{
    local module_cache

    if [ "$#" -lt 2 ]; then
        echo "Usage: video-concat FILE1 FILE2 [FILE3 ...]" >&2
        return 2
    fi

    command -v swift >/dev/null 2>&1 || {
        echo "swift not found" >&2
        return 127
    }

    module_cache=${TMPDIR:-/tmp}/video-splicer-module-cache
    mkdir -p "$module_cache" || return 1

    swift -module-cache-path "$module_cache" \
        "$_video_files_compactor_dir/video-concat.swift" "$@"
}
