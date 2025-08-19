#!/bin/bash

# Description: Captures screenshots or uploads files and uploads them to a CDN.
# Author: https://github.com/RealFascinated

# --- Configuration ---
MINIO_ENDPOINT="${MINIO_ENDPOINT}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY}"
BUCKET_NAME="${BUCKET_NAME}"
URL_BASE="${URL_BASE}"
SOUND_VOLUME="${SOUND_VOLUME:-1}"
FILENAME_LENGTH="${FILENAME_LENGTH:-8}"

# --- Setup ---
MC_CONFIG_DIR="$HOME/.mc"
mkdir -p "$MC_CONFIG_DIR"
SCREENSHOT_PATH=""

# Check for required Wayland clipboard tools
command -v wl-paste &>/dev/null || {
    echo "Error: wl-paste not found. Please install wl-clipboard." >&2
    exit 1
}
command -v wl-copy &>/dev/null || {
    echo "Error: wl-copy not found. Please install wl-clipboard." >&2
    exit 1
}

# Check for MinIO client (mc)
command -v mc &>/dev/null || {
    echo "Error: MinIO client (mc) not installed" >&2
    exit 1
}

# Check for exiftool (for EXIF removal)
command -v exiftool &>/dev/null || {
    echo "Warning: exiftool not found. EXIF data will not be removed." >&2
}

# --- Cleanup ---
cleanup() {
    [[ -f "$SCREENSHOT_PATH" ]] && rm -f "$SCREENSHOT_PATH"
}
trap cleanup EXIT

# --- Utility Functions ---
log_url() {
    local url="$1" size="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Size: $size - URL: $url" >> "$HOME/.cdn_urls.log"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  -h, --help           Show this help message
  -u, --upload SOURCE  Upload file from local path or URL
  -c, --clipboard      Upload from clipboard content (file path or URL)
  -v, --volume VOL     Set sound volume (default: $SOUND_VOLUME)
  -l, --length LEN     Set random filename length (default: $FILENAME_LENGTH)

Examples:
  $0                                   Take and upload a screenshot
  $0 -u image.png                      Upload local file
  $0 -u https://example.com/image.png  Upload from URL
  $0 -c                                Upload from clipboard content
  $0 -v 0.5                            Take screenshot with 50% volume
  $0 -l 12                             Generate 12-character filenames
EOF
}

parse_args() {
    UPLOAD_FILE="" CLIPBOARD_MODE=false
    
    while getopts ":hu:cv:l:" opt; do
        case $opt in
            h) show_help; exit 0 ;;
            u) UPLOAD_FILE="$OPTARG" ;;
            c) CLIPBOARD_MODE=true ;;
            v) 
                if ! [[ "$OPTARG" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$OPTARG > 1" | bc -l) )); then
                    echo "Error: Volume must be between 0 and 1" >&2; exit 1
                fi
                SOUND_VOLUME="$OPTARG" ;;
            l)
                if ! [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: Filename length must be a positive integer" >&2; exit 1
                fi
                FILENAME_LENGTH="$OPTARG" ;;
            :) echo "Error: Option -$OPTARG requires an argument" >&2; show_help; exit 1 ;;
            \?) echo "Error: Invalid option -$OPTARG" >&2; show_help; exit 1 ;;
        esac
    done

    # Handle long options
    for arg in "$@"; do
        case "$arg" in
            --help) show_help; exit 0 ;;
            --upload=*) UPLOAD_FILE="${arg#*=}" ;;
            --clipboard) CLIPBOARD_MODE=true ;;
            --volume=*)
                local vol="${arg#*=}"
                if ! [[ "$vol" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$vol > 1" | bc -l) )); then
                    echo "Error: Volume must be between 0 and 1" >&2; exit 1
                fi
                SOUND_VOLUME="$vol" ;;
            --length=*)
                local len="${arg#*=}"
                if ! [[ "$len" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: Filename length must be a positive integer" >&2; exit 1
                fi
                FILENAME_LENGTH="$len" ;;
            --*) echo "Error: Unknown long option: $arg" >&2; show_help; exit 1 ;;
        esac
    done

    if [[ -n "$UPLOAD_FILE" && "$CLIPBOARD_MODE" == true ]]; then
        echo "Error: Cannot use both --upload and --clipboard options" >&2; show_help; exit 1
    fi
}

generate_random_name() {
    < /dev/urandom tr -dc 'a-zA-Z' | head -c "$FILENAME_LENGTH"
}

format_file_size() {
    local size_bytes=$1
    if ((size_bytes < 1024)); then
        echo "${size_bytes} bytes"
    elif ((size_bytes < 1048576)); then
        printf "%.2f KB\n" "$(echo "scale=2; $size_bytes/1024" | bc)"
    elif ((size_bytes < 1073741824)); then
        printf "%.2f MB\n" "$(echo "scale=2; $size_bytes/1048576" | bc)"
    else
        printf "%.2f GB\n" "$(echo "scale=2; $size_bytes/1073741824" | bc)"
    fi
}

send_notification() {
    local title="$1" message="$2" icon="${3:-image-x-generic}"
    notify-send --icon="$icon" --urgency=normal --app-name="CDN Upload" "$title" "$message"
}

copy_to_clipboard() {
    local text="$1" size="$2"
    log_url "$text" "$size"
    
    printf "%s" "$text" | wl-copy
    echo "URL copied to clipboard (Wayland)" >&2
}

# Copies image file to clipboard
copy_image_to_clipboard() {
    local image_path="$1"
    
    wl-copy < "$image_path"
    echo "Image copied to clipboard (Wayland)" >&2
    return 0
}

# Removes EXIF data from files
remove_exif_data() {
    local file_path="$1"
    
    if command -v exiftool &>/dev/null; then
        # Check if file has EXIF data (suppress all output)
        if exiftool -q -fast2 "$file_path" 2>/dev/null | grep -q .; then
            echo "Removing EXIF data from: $file_path" >&2
            # Remove all metadata and suppress output
            exiftool -all= -overwrite_original -q "$file_path" >/dev/null 2>&1 || {
                echo "Warning: Failed to remove EXIF data" >&2
            }
        fi
    fi
}

# Saves clipboard content to a temporary file
save_clipboard_content() {
    local tmp_file="/tmp/$(generate_random_name)"
    
    # Try to detect if it's an image first
    if wl-paste --list-types | grep -q "image/"; then
        local image_type=$(wl-paste --list-types | grep "image/" | head -n1)
        wl-paste --type "$image_type" > "$tmp_file"
        echo "Saved clipboard image as: $tmp_file" >&2
        remove_exif_data "$tmp_file"
        echo "$tmp_file"
        return 0
    else
        # Handle text content
        wl-paste --no-newline > "$tmp_file"
        echo "Saved clipboard text as: $tmp_file" >&2
        echo "$tmp_file"
        return 0
    fi
}

# Centralized error handler
handle_error() {
    local error_type="$1"
    local error_message="$2"
    local file_path="$3"
    
    play_sound "$ERROR_SOUND"
    
    if [[ -n "$file_path" && -f "$file_path" ]]; then
        copy_image_to_clipboard "$file_path" && {
            send_notification "❌ $error_type" "$error_message\nImage copied to clipboard as fallback" "edit-copy"
        } || {
            send_notification "❌ $error_type" "$error_message\nCould not copy to clipboard" "dialog-error"
        }
    else
        send_notification "❌ $error_type" "$error_message" "dialog-error"
    fi
    
    return 1
}

# Saves image to local fallback directory
save_image_locally() {
    local image_path="$1"
    local fallback_dir="$HOME/Pictures/cdn_fallback"
    
    mkdir -p "$fallback_dir" || return 1
    
    local filename=$(basename "$image_path")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local fallback_path="$fallback_dir/${timestamp}_${filename}"
    
    cp "$image_path" "$fallback_path" && {
        echo "Image saved locally: $fallback_path" >&2
        echo "$fallback_path"
        return 0
    }
    return 1
}

is_url() {
    local url="$1"
    if [[ "$url" =~ ^https?:// ]]; then
        [[ "$url" =~ ^https?://[^[:space:]]+ ]] && return 0
    elif [[ "$url" =~ ^file:// ]]; then
        local path="${url#file://}" && path="${path//%20/ }"
        [[ -f "$path" ]] && echo "$path" && return 2
    fi
    return 1
}

is_valid_path() {
    local path="$1"
    if [[ -n "$path" && ! "$path" =~ [\<\>\:\"\|\\\?\*] ]]; then
        if [[ "$path" != */* ]]; then
            [[ -f "$path" ]] && return 0
        else
            local dir="${path%/*}" && [[ -d "$dir" ]] && return 0
        fi
    fi
    return 1
}

confirm_upload() {
    local file_path="$1" file_size="$2" formatted_size="$3"
    (( file_size <= 64 * 1024 * 1024 )) && return 0 # 64MB
    
    command -v zenity &>/dev/null || {
        echo "Warning: File is large ($formatted_size). Continuing with upload..." >&2; return 0
    }
    
    zenity --question \
        --title="Large File Upload" \
        --window-icon="system-file-manager" \
        --icon-name="system-file-manager" \
        --text="<span size='large' weight='bold'>Large File Detected</span>" \
        --text="<span size='large'>$(basename "$file_path")</span>\n\nSize: <b>$formatted_size</b>\n\nDo you want to continue with the upload?" \
        --width=450 --height=250 \
        --ok-label="Upload" --cancel-label="Cancel" --no-wrap
}

# --- Core Functions ---

download_from_url() {
    local url="$1"
    local clean_url="${url%%\?*}"
    local filename=$(basename "$clean_url")
    
    # Handle Tenor URLs specifically
    if [[ "$url" == *"tenor.com"* ]]; then
        echo "Processing Tenor URL..." >&2
        local media_url=$(curl -s "$url" | grep -o 'https://media[^"]*\.\(gif\|mp4\)' | head -1)
        if [[ -n "$media_url" ]]; then
            echo "Found media URL: $media_url" >&2
            url="$media_url"
            filename=$(basename "$media_url")
        else
            echo "Error: Could not extract media URL from Tenor page" >&2
            handle_error "Download Failed" "Could not extract media URL from Tenor page"
        fi
    fi
    
    # Handle compound extensions
    local file_ext=""
    case "$filename" in
        *.tar.gz|*.tgz) file_ext="tar.gz" ;;
        *.tar.xz|*.txz) file_ext="tar.xz" ;;
        *.tar.bz2|*.tbz2) file_ext="tar.bz2" ;;
        *.tar.zst|*.tzst) file_ext="tar.zst" ;;
        *.tar.lz|*.tlz) file_ext="tar.lz" ;;
        *.tar.lzma|*.tlzma) file_ext="tar.lzma" ;;
        *)
            if [[ "$filename" == *.* ]]; then
                local last_part="${filename##*.}"
                [[ "$last_part" =~ ^[a-zA-Z0-9]+$ ]] && file_ext="$last_part"
            fi
            ;;
    esac
    
    # Handle Discord CDN URLs
    if [[ -z "$file_ext" && "$url" == *"cdn.discordapp.com"* ]]; then
        local content_type=$(curl -sI "$url" | grep -i "Content-Type:" | cut -d' ' -f2 | tr -d '\r')
        case "$content_type" in
            "image/gif") file_ext="gif" ;;
            "image/png") file_ext="png" ;;
            "image/jpeg") file_ext="jpg" ;;
            "image/webp") file_ext="webp" ;;
            *) [[ "$filename" == *.* ]] && file_ext="${filename##*.}" || file_ext="bin" ;;
        esac
    fi
    
    local tmp_file
    [[ -n "$file_ext" ]] && tmp_file="/tmp/$(generate_random_name).$file_ext" || tmp_file="/tmp/$(generate_random_name)"
    
    echo "Downloading from URL..." >&2
    curl -L -s -o "$tmp_file" "$url" || {
        echo "Error: Failed to download from URL" >&2
        handle_error "Download Failed" "Failed to download from URL"
    }
    
    # Remove EXIF data after download
    remove_exif_data "$tmp_file"
    
    echo "$tmp_file"
}

upload_file() {
    local source="$1" file_path
    
    # Handle file:// URLs specially
    if [[ "$source" =~ ^file:// ]]; then
        local path="${source#file://}" && path="${path//%20/ }"
        if [[ -f "$path" ]]; then
            file_path="$path"
            # Remove EXIF data from local file
            remove_exif_data "$file_path"
        else
            echo "Error: File not found: $path" >&2; return 1
        fi
    elif is_url "$source"; then
        file_path=$(download_from_url "$source") || return 1
        SCREENSHOT_PATH="$file_path"
    else
        if [[ "$source" != */* ]]; then
            [[ -f "$source" ]] && file_path="$source" || {
                echo "Error: File not found: $source" >&2; return 1
            }
        else
            file_path="$source"
        fi
        # Remove EXIF data from local file
        remove_exif_data "$file_path"
    fi

    [[ -f "$file_path" && -r "$file_path" ]] || {
        echo "Error: File not found or not readable: $file_path" >&2
        handle_error "Upload Failed" "File not found or not readable"
    }

    # Get file extension
    local file_ext="" base_name=$(basename "$file_path")
    case "$base_name" in
        *.tar.gz|*.tgz) file_ext="tar.gz" ;;
        *.tar.xz|*.txz) file_ext="tar.xz" ;;
        *.tar.bz2|*.tbz2) file_ext="tar.bz2" ;;
        *.tar.zst|*.tzst) file_ext="tar.zst" ;;
        *.tar.lz|*.tlz) file_ext="tar.lz" ;;
        *.tar.lzma|*.tlzma) file_ext="tar.lzma" ;;
        *)
            if [[ "$base_name" == *.* ]]; then
                local last_part="${base_name##*.}"
                [[ "$last_part" =~ ^[a-zA-Z0-9]+$ ]] && file_ext="$last_part"
            fi
            ;;
    esac
    
    local random_name
    [[ -n "$file_ext" ]] && random_name="$(generate_random_name).$file_ext" || random_name="$(generate_random_name)"
    
    local file_size=$(stat -c%s "$file_path")
    local formatted_size=$(format_file_size "$file_size")
    local public_url="$URL_BASE/$random_name"
    local file_name=$(basename "$file_path")

    confirm_upload "$file_path" "$file_size" "$formatted_size" || {
        echo "Upload cancelled by user" >&2
        handle_error "Upload Cancelled" "Upload was cancelled by user"
    }

    echo "Attempting to upload: $file_path as $random_name ($formatted_size)" >&2

    mc --config-dir "$MC_CONFIG_DIR" cp "$file_path" "minio/$BUCKET_NAME/$random_name" >&2 || {
        echo "Upload failed!" >&2
        return $(handle_error "Upload Failed" "Failed to upload to CDN" "$file_path")
    }

    send_notification "✅ Upload Complete" "$public_url\n$formatted_size" "image-x-generic"
    copy_to_clipboard "$public_url" "$formatted_size"
    echo "Public URL: $public_url" >&2
    echo "File Size: $formatted_size" >&2
}

capture_screenshot() {
    local random_name="$(generate_random_name).png"
    local tmp_file="/tmp/$random_name"

    echo "Capturing screenshot..." >&2
    timeout 30 spectacle --background --region --nonotify --output "$tmp_file" || exit 0
    
    [[ -f "$tmp_file" ]] || exit 0
    
    SCREENSHOT_PATH="$tmp_file"
    echo "$tmp_file"
}

handle_clipboard_upload() {
    # First, try to detect if clipboard contains an image
    if wl-paste --list-types | grep -q "image/"; then
        echo "Detected image in clipboard, saving and uploading..." >&2
        local tmp_file=$(save_clipboard_content) || {
            echo "Error: Failed to save clipboard content" >&2
            handle_error "Upload Failed" "Failed to save clipboard content"
        }
        SCREENSHOT_PATH="$tmp_file"
        upload_file "$tmp_file" || return 1
        return 0
    fi

    # If no image detected, try to get text content
    local clipboard_content=$(wl-paste --no-newline | tr -d '\0') || {
        echo "Error: Clipboard is empty" >&2
        handle_error "Upload Failed" "Clipboard is empty"
    }

    clipboard_content="${clipboard_content#"${clipboard_content%%[![:space:]]*}"}"
    clipboard_content="${clipboard_content%"${clipboard_content##*[![:space:]]}"}"
    
    local file_path=$(is_url "$clipboard_content")
    local url_status=$?
    
    if [[ $url_status -eq 2 ]]; then
        echo "Using converted file path: $file_path" >&2
        upload_file "$file_path" || return 1
    elif [[ $url_status -eq 0 ]]; then
        upload_file "$clipboard_content" || return 1
    elif is_valid_path "$clipboard_content"; then
        upload_file "$clipboard_content" || return 1
    else
        # If it's not a URL or file path, save it as a text file and upload
        echo "Saving clipboard content as text file and uploading..." >&2
        local tmp_file=$(save_clipboard_content) || {
            echo "Error: Failed to save clipboard content" >&2
            handle_error "Upload Failed" "Failed to save clipboard content"
        }
        SCREENSHOT_PATH="$tmp_file"
        upload_file "$tmp_file" || return 1
    fi
}

handle_file_upload() {
    local file="$1"
    echo "Handling file upload for: $file" >&2
    
    if is_url "$file"; then
        echo "File is a URL" >&2
        upload_file "$file" || return 1
    elif ! is_valid_path "$file"; then
        if [[ "$file" != /* ]]; then
            local abs_path="$PWD/$file"
            echo "Trying absolute path: $abs_path" >&2
            if [[ -f "$abs_path" ]]; then
                upload_file "$abs_path" || return 1
            fi
        fi
        echo "Error: Invalid file path format" >&2
        handle_error "Upload Failed" "Invalid file path format"
    elif [[ ! -f "$file" ]]; then
        echo "Error: File not found at specified path: $file" >&2
        handle_error "Upload Failed" "File not found: $file"
    else
        upload_file "$file" || return 1
    fi
}

handle_screenshot() {
    local screenshot_file=$(capture_screenshot)
    [[ -n "$screenshot_file" ]] && {
        play_sound "$CAPTURE_SOUND"
        upload_file "$screenshot_file" && play_sound "$COMPLETE_SOUND"
    }
}

# --- Main Execution ---
main() {
    UPLOAD_FILE="" 
    CLIPBOARD_MODE=false
    parse_args "$@"

    # Always set the alias (will overwrite if it exists)
    mc --config-dir "$MC_CONFIG_DIR" alias set minio \
        "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" >/dev/null 2>&1

    # Sound setup
    CAPTURE_SOUND="/tmp/CaptureSound.wav"
    COMPLETE_SOUND="/tmp/TaskCompletedSound.wav"
    ERROR_SOUND="/tmp/ErrorSound.wav"

    get_sound() {
        local file="$1" url="$2"
        [[ ! -f "$file" ]] || [[ $(stat -c%s "$file") -lt 1000 ]] && {
            curl -L -s -o "$file" "$url" || {
                echo "Failed to download sound" >&2; return 1
            }
        }
    }

    get_sound "$CAPTURE_SOUND" "https://cdn.fascinated.cc/sounds/cdn/CaptureSound.wav"
    get_sound "$COMPLETE_SOUND" "https://cdn.fascinated.cc/sounds/cdn/TaskCompletedSound.wav"
    get_sound "$ERROR_SOUND" "https://cdn.fascinated.cc/sounds/cdn/ErrorSound.wav"

    play_sound() {
        [[ -f "$1" ]] && pw-cat -p --volume $SOUND_VOLUME "$1" &> /dev/null &   
    }

    if [[ "$CLIPBOARD_MODE" == true ]]; then
        handle_clipboard_upload && play_sound "$COMPLETE_SOUND"
    elif [[ -n "$UPLOAD_FILE" ]]; then
        handle_file_upload "$UPLOAD_FILE" && play_sound "$COMPLETE_SOUND"
    else
        handle_screenshot
    fi
}

main "$@"
