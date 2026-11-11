#!/bin/bash
# ==============================================================================
# backup_engine.sh  —  SourceStream Core Backup Engine
# Bundled at: SourceStream.app/Contents/Resources/backup_engine.sh
#
# CONFIG:   ~/.sourcestream/config/sourcestream.conf
# LOGS:     ~/.sourcestream/logs/
# STATUS:   ~/.sourcestream/status.json
#
# CRONTAB (set by installer — no stderr suppression):
#   0 23 * * 0 /Applications/SourceStream.app/Contents/Resources/backup_engine.sh
# ==============================================================================

# ── Paths ──────────────────────────────────────────────────────────────────────
SS_DIR="$HOME/.sourcestream"
CONF_FILE="$SS_DIR/config/sourcestream.conf"
LOG_DIR="$SS_DIR/logs"
OUTPUT_LOG="$LOG_DIR/backup.log"
ERROR_LOG="$LOG_DIR/error.log"
STATUS_JSON="$SS_DIR/status.json"
MANIFEST_DIR="$SS_DIR/manifests"      # stores per-source incremental timestamps
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Progress-tracking globals (written to status.json)
CURRENT_ARCHIVE_PATH=""    # set before tar starts
ESTIMATED_SIZE_MB=0        # set by preflight_space_check

mkdir -p "$LOG_DIR" "$SS_DIR/config" "$MANIFEST_DIR"

# ── Logging ───────────────────────────────────────────────────────────────────
# Write directly to log file — do NOT use tee (wrapper script also redirects
# stdout → backup.log, so tee would cause every line to appear twice).
log_msg() {
    local TYPE="$1" MSG="$2" TS
    TS=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TS] $TYPE: $MSG" >> "$OUTPUT_LOG"
}
log_err() {
    local MSG="$1" TS
    TS=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TS] ERROR: $MSG" >> "$ERROR_LOG"
    echo "[$TS] ERROR: $MSG" >> "$OUTPUT_LOG"
}

# ── Defaults ──────────────────────────────────────────────────────────────────
DIRECT_TO_DRIVE="true"
MAX_ARCHIVES_TO_KEEP=3
COMPRESSION_LEVEL=6          # gzip 1(fast)–9(best), default 6
ARCHIVE_PREFIX="{label}"     # archive name template: {label}, {hostname}, {date}
HOSTNAME_IN_NAME="false"
SOURCE_ENTRIES=()
DEST_ENTRIES=()
REMOTE_DEST_ENTRIES=()     # s3://bucket/path|Label  or  b2://bucket/path|Label
CUSTOM_EXCLUDES=()
SOURCE_EXCL_LINES=()       # per-source excludes: "path:pattern" entries
CURRENT_EXCL_SRC=""        # active source path while parsing [excludes:/path] sections
BACKUP_VERIFY="false"      # auto-verify archive integrity after each backup
ARCHIVE_FORMAT="zip"      # archive type: tar.gz | tar.bz2 | tar.xz | zip
BACKUP_MODE="full"         # backup mode: full | incremental
SS_DRY_RUN="${SS_DRY_RUN:-}"  # set by server for dry-run mode (env override)

# ── Auto-detect Google Drive path (any user, any Google account) ───────────────
detect_gdrive() {
    local cs="$HOME/Library/CloudStorage"
    if [ -d "$cs" ]; then
        # Pick first GoogleDrive-* folder found (handles any email address)
        local d
        for d in "$cs"/GoogleDrive-*/; do
            [ -d "${d}My Drive" ] && { echo "${d}My Drive/SourceStream Backups"; return; }
        done
    fi
    # Legacy Google Drive location
    for d in "$HOME/Google Drive/My Drive" "$HOME/Google Drive"; do
        [ -d "$d" ] && { echo "$d/SourceStream Backups"; return; }
    done
    # Fallback — user will configure via Dashboard
    echo "$HOME/Library/CloudStorage/GoogleDrive/My Drive/SourceStream Backups"
}

# ── Initialize config if missing ──────────────────────────────────────────────
initialize_config() {
    if [ ! -f "$CONF_FILE" ]; then
        mkdir -p "$(dirname "$CONF_FILE")"
        local DEFAULT_GDRIVE
        DEFAULT_GDRIVE="$(detect_gdrive)"
        cat > "$CONF_FILE" << CONF
# SourceStream Configuration
# ~/.sourcestream/config/sourcestream.conf
# Managed by SourceStream Dashboard or edited manually.

[settings]
DIRECT_TO_DRIVE=true
MAX_ARCHIVES_TO_KEEP=3
COMPRESSION_LEVEL=6
ARCHIVE_PREFIX={label}
HOSTNAME_IN_NAME=false
ARCHIVE_FORMAT=zip
BACKUP_VERIFY=false
NOTIFY_ON_COMPLETE=true
BACKUP_MODE=full

[sources]
$HOME/Developer|Developer

[destinations]
$DEFAULT_GDRIVE|Google Drive

[excludes]
CONF
        log_msg "INFO" "Created default config: $CONF_FILE"
        log_msg "INFO" "   Auto-detected destination: $DEFAULT_GDRIVE"
    fi
}

# ── Parse config (bash 3.2 compatible — no readarray) ─────────────────────────
load_config() {
    local section="" trimmed
    CURRENT_EXCL_SRC=""
    [ ! -f "$CONF_FILE" ] && return
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        # Match [section] or [excludes:/path/to/source]
        if [[ "$trimmed" =~ ^\[(.+)\]$ ]]; then
            local hdr="${BASH_REMATCH[1]}"
            if [[ "$hdr" == excludes:* ]]; then
                section="source_excludes"
                CURRENT_EXCL_SRC="${hdr#excludes:}"
            else
                section="$hdr"
                CURRENT_EXCL_SRC=""
            fi
            continue
        fi

        case "$section" in
            settings)
                if [[ "$trimmed" == *=* ]]; then
                    local key="${trimmed%%=*}" val="${trimmed#*=}"
                    key="${key//[[:space:]]/}"; val="${val//[[:space:]]/}"
                    case "$key" in
                        DIRECT_TO_DRIVE)      DIRECT_TO_DRIVE="$val" ;;
                        MAX_ARCHIVES_TO_KEEP) MAX_ARCHIVES_TO_KEEP="$val" ;;
                        COMPRESSION_LEVEL)    COMPRESSION_LEVEL="$val" ;;
                        ARCHIVE_PREFIX)       ARCHIVE_PREFIX="$val" ;;
                        HOSTNAME_IN_NAME)     HOSTNAME_IN_NAME="$val" ;;
                        BACKUP_VERIFY)        BACKUP_VERIFY="$val" ;;
                        ARCHIVE_FORMAT)       ARCHIVE_FORMAT="$val" ;;
                        NOTIFY_ON_COMPLETE)   NOTIFY_ON_COMPLETE="$val" ;;
                        BACKUP_MODE)          BACKUP_MODE="$val" ;;
                    esac
                fi
                ;;
            sources)        [[ "$trimmed" == *"|"* ]] && SOURCE_ENTRIES+=("$trimmed") ;;
            destinations)   [[ "$trimmed" == *"|"* ]] && DEST_ENTRIES+=("$trimmed") ;;
            remote_destinations) [[ "$trimmed" == *"|"* ]] && REMOTE_DEST_ENTRIES+=("$trimmed") ;;
            excludes)       [[ -n "$trimmed" ]] && CUSTOM_EXCLUDES+=("$trimmed") ;;
            source_excludes)
                [[ -n "$trimmed" && -n "$CURRENT_EXCL_SRC" ]] &&                     SOURCE_EXCL_LINES+=("${CURRENT_EXCL_SRC}:${trimmed}") ;;
        esac
    done < "$CONF_FILE"
}

initialize_config
load_config

# ── Boot banner ───────────────────────────────────────────────────────────────
log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "INFO" "🚀 SourceStream Backup Engine starting..."
log_msg "INFO" "   PID: $$  |  User: $(whoami)"
log_msg "INFO" "   Mode: DIRECT_TO_DRIVE=$DIRECT_TO_DRIVE  |  Retention: $MAX_ARCHIVES_TO_KEEP archives"
log_msg "INFO" "   Sources:      ${#SOURCE_ENTRIES[@]} configured"
log_msg "INFO" "   Destinations: ${#DEST_ENTRIES[@]} configured"
log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_SHORT=$(hostname -s 2>/dev/null | tr -cd '[:alnum:]_-' | cut -c1-20)
NOTIFY_ON_COMPLETE="${NOTIFY_ON_COMPLETE:-false}"

# ── Archive name helper ────────────────────────────────────────────────────────
# Builds archive filename from config template.
# Template tokens:  {label} → sanitized source label
#                   {hostname} → machine short hostname
#                   {date} → YYYYMMDD
#                   {time} → HHMMSS
# Default template "{label}" produces:  Developer_20261109_020001.tar.gz
make_archive_name() {
    local RAW_LABEL="$1"
    # Sanitize: spaces→underscores, strip special chars, max 40 chars
    local SAFE_LABEL
    SAFE_LABEL=$(echo "$RAW_LABEL" | tr ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-40)
    [ -z "$SAFE_LABEL" ] && SAFE_LABEL="Backup"

    local DATE_PART TIME_PART
    DATE_PART=$(date +"%Y%m%d")
    TIME_PART=$(date +"%H%M%S")

    # Bug fix: "${ARCHIVE_PREFIX:-{label}}" is ambiguous in bash 3.2 when
    # ARCHIVE_PREFIX is already set to "{label}" — the outer } closes the
    # parameter expansion early, leaving a stray literal } in the name.
    # Use an explicit empty-check guard instead.
    local _PFX="$ARCHIVE_PREFIX"
    [ -z "$_PFX" ] && _PFX="{label}"
    local TEMPLATE="$_PFX"
    local NAME="$TEMPLATE"
    NAME="${NAME//\{label\}/$SAFE_LABEL}"
    NAME="${NAME//\{hostname\}/$HOSTNAME_SHORT}"
    NAME="${NAME//\{date\}/$DATE_PART}"
    NAME="${NAME//\{time\}/$TIME_PART}"

    # Always append timestamp suffix so archives never overwrite each other
    local EXT; EXT=$(get_archive_ext)
    echo "${NAME}_${DATE_PART}_${TIME_PART}.${EXT}"
}

# ── Archive format helpers ─────────────────────────────────────────────────────
get_archive_ext() {
    case "${ARCHIVE_FORMAT:-tar.gz}" in
        tar.bz2) echo "tar.bz2" ;;
        tar.xz)  echo "tar.xz"  ;;
        zip)     echo "zip"     ;;
        *)       echo "tar.gz"  ;;
    esac
}
get_tar_comp_flag() {
    # Returns the compression flag for tar (not used for zip)
    case "${ARCHIVE_FORMAT:-tar.gz}" in
        tar.bz2) echo "j" ;;
        tar.xz)  echo "J" ;;
        *)       echo "z" ;;   # tar.gz default
    esac
}

# ── Per-source keep override ───────────────────────────────────────────────────
# Source entry format: /path|Label  or  /path|Label|keep=N
# Returns the effective keep value for the given source entry.
get_source_keep() {
    local ENTRY="$1"
    local P1 P2 P3
    # Split on | — bash 3.2 compat (no readarray; use while+IFS or manual split)
    P1="${ENTRY%%|*}"
    local REST="${ENTRY#*|}"
    P2="${REST%%|*}"
    P3="${REST#*|}"
    [[ "$P3" == "$P2" ]] && P3=""   # no 3rd field
    if [[ "$P3" == keep=* ]]; then
        local K="${P3#keep=}"
        K=$(( ${K:-0} + 0 ))
        [ "$K" -gt 0 ] && echo "$K" && return
    fi
    echo "$MAX_ARCHIVES_TO_KEEP"
}

# ── Per-source excludes helper ─────────────────────────────────────────────────
# Returns --exclude=pattern lines for the given source path.
# Outputs one flag per line; caller reads with while loop.
build_source_excludes() {
    local SRC_PATH="$1"
    local LINE LPATH LPAT
    for LINE in "${SOURCE_EXCL_LINES[@]}"; do
        LPATH="${LINE%%:*}"
        LPAT="${LINE#*:}"
        [[ "$LPATH" == "$SRC_PATH" ]] && echo "--exclude=${LPAT}"
    done
}

# ── Archive verify (format-aware) ─────────────────────────────────────────────
verify_archive() {
    local ARCH="$1"
    case "$ARCH" in
        *.tar.bz2) tar -tjf "$ARCH" > /dev/null 2>&1 ;;
        *.tar.xz)  tar -tJf "$ARCH" > /dev/null 2>&1 ;;
        *.zip)     unzip -t  "$ARCH" > /dev/null 2>&1 ;;
        *)         tar -tzf  "$ARCH" > /dev/null 2>&1 ;;
    esac
}

# ==============================================================================
# FUNCTION: upload_to_remote
# Uploads a local archive file to a remote destination (S3 or B2).
#
# Remote destination entry format: <scheme>://<bucket>/<prefix>|<Label>
#   e.g.  s3://my-backup-bucket/sourcestream|AWS S3
#         b2://my-bucket/sourcestream|Backblaze B2
#         rclone:remote:path|Rclone
#
# CLIs used (must be installed separately by the user):
#   - s3://  → aws s3 cp   (aws-cli: brew install awscli)
#   - b2://  → b2 file upload-file  (b2-tools: brew install b2-tools)
#   - rclone:→ rclone copy   (brew install rclone)
#
# Returns 0 on success, 1 on error (never aborts whole backup).
# ==============================================================================
upload_to_remote() {
    local LOCAL_ARCHIVE="$1"
    local REMOTE_URI="$2"      # s3://bucket/prefix  |  b2://bucket/prefix  |  rclone:remote:path
    local REMOTE_LABEL="$3"
    local FNAME
    FNAME=$(basename "$LOCAL_ARCHIVE")

    log_msg "INFO" "☁️  Uploading to $REMOTE_LABEL..."
    log_msg "INFO" "   Local:  $LOCAL_ARCHIVE"
    log_msg "INFO" "   Remote: ${REMOTE_URI}/${FNAME}"

    case "$REMOTE_URI" in
        s3://*)
            if ! command -v aws &>/dev/null; then
                log_err "AWS CLI not found — cannot upload to $REMOTE_LABEL. Install: brew install awscli"
                return 1
            fi
            aws s3 cp "$LOCAL_ARCHIVE" "${REMOTE_URI}/${FNAME}" \
                --no-progress 2>>"$ERROR_LOG"
            local EXIT=$?
            if [ "$EXIT" -eq 0 ]; then
                log_msg "SUCCESS" "   ✅ Uploaded to $REMOTE_LABEL: ${REMOTE_URI}/${FNAME}"
            else
                log_err "   ❌ Upload to $REMOTE_LABEL failed (exit $EXIT). Check $ERROR_LOG"
                return 1
            fi
            ;;
        b2://*)
            if ! command -v b2 &>/dev/null; then
                log_err "B2 CLI not found — cannot upload to $REMOTE_LABEL. Install: brew install b2-tools"
                return 1
            fi
            # b2 upload: b2 file upload-file <bucket> <localFile> <remoteName>
            # Extract bucket name: b2://bucket/prefix → bucket
            local B2_BUCKET; B2_BUCKET="${REMOTE_URI#b2://}"; B2_BUCKET="${B2_BUCKET%%/*}"
            local B2_PREFIX; B2_PREFIX="${REMOTE_URI#b2://${B2_BUCKET}}"; B2_PREFIX="${B2_PREFIX#/}"
            local B2_REMOTE_NAME="${B2_PREFIX:+${B2_PREFIX}/}${FNAME}"
            b2 file upload-file "$B2_BUCKET" "$LOCAL_ARCHIVE" "$B2_REMOTE_NAME" \
                2>>"$ERROR_LOG" >/dev/null
            local EXIT=$?
            if [ "$EXIT" -eq 0 ]; then
                log_msg "SUCCESS" "   ✅ Uploaded to $REMOTE_LABEL: b2://${B2_BUCKET}/${B2_REMOTE_NAME}"
            else
                log_err "   ❌ B2 upload to $REMOTE_LABEL failed (exit $EXIT). Check $ERROR_LOG"
                return 1
            fi
            ;;
        rclone:*)
            if ! command -v rclone &>/dev/null; then
                log_err "rclone not found — cannot upload to $REMOTE_LABEL. Install: brew install rclone"
                return 1
            fi
            # rclone:remote:path → rclone copy localFile remote:path
            local RCLONE_DEST="${REMOTE_URI#rclone:}"
            rclone copy "$LOCAL_ARCHIVE" "$RCLONE_DEST" \
                --progress=false 2>>"$ERROR_LOG"
            local EXIT=$?
            if [ "$EXIT" -eq 0 ]; then
                log_msg "SUCCESS" "   ✅ Uploaded via rclone to $REMOTE_LABEL: $RCLONE_DEST/$FNAME"
            else
                log_err "   ❌ rclone upload to $REMOTE_LABEL failed (exit $EXIT). Check $ERROR_LOG"
                return 1
            fi
            ;;
        *)
            log_err "Unknown remote scheme in '$REMOTE_URI' — supported: s3://, b2://, rclone:"
            return 1
            ;;
    esac
    return 0
}

# ── Exit trap — remove partial archives if engine crashes mid-backup ─────────────
_PARTIAL_FILES=()
trap 'for pf in "${_PARTIAL_FILES[@]}"; do [ -f "$pf" ] && rm -f "$pf" && log_msg "WARN" "🧹 Cleaned up partial archive: $(basename "$pf")"; done' EXIT

# ── Dry-run mode ──────────────────────────────────────────────────────────────
    if [ -n "$SS_DRY_RUN" ]; then
    log_msg "INFO" "🔍 DRY-RUN MODE — no archives will be written."
    for SRC_ENTRY in "${SOURCE_ENTRIES[@]}"; do
        SRC_PATH="${SRC_ENTRY%%|*}"
        SRC_NAME="${SRC_ENTRY#*|}"; SRC_NAME="${SRC_NAME%%|*}"
        log_msg "INFO" "   📂 Would backup: $SRC_NAME ($SRC_PATH)"
        FC=$(find "$SRC_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
        SZ=$(du -sh "$SRC_PATH" 2>/dev/null | cut -f1 || echo "?")
        log_msg "INFO" "      Files: ~$FC  |  Raw size: $SZ"
        ARCNAME=$(make_archive_name "$SRC_NAME")
        log_msg "INFO" "      Would create: $ARCNAME"
        # Incremental dry-run: show changed file count
        if [ "${BACKUP_MODE:-full}" = "incremental" ]; then
            CHANGED=$(count_changed_files "$SRC_PATH" "$SRC_NAME")
            CHANGED=$(( ${CHANGED:-0} + 0 ))
            MANIFEST=$(get_manifest_path "$SRC_NAME")
            if [ -f "$MANIFEST" ]; then
                LAST_TS=$(cat "$MANIFEST" 2>/dev/null || echo "unknown")
                log_msg "INFO" "      Incremental: $CHANGED changed file(s) since $LAST_TS"
            else
                log_msg "INFO" "      Incremental: first run — full baseline ($FC files)"
            fi
        fi
    done
    log_msg "INFO" "🔍 DRY-RUN complete. No files written."
    exit 0
fi

# ── Flush leftover /tmp fragments from aborted sessions ───────────────────────
# Only clean up archives that look like they were created by SourceStream
# (they all start with an alphanumeric label and have a _YYYYMMDD_ datestamp).
# We deliberately avoid 'rm -f /tmp/*.tar.gz' which could clobber other apps.
for _TMP_EXT in tar.gz tar.bz2 tar.xz zip; do
    for _TMP_F in /tmp/*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]."${_TMP_EXT}"; do
        [ -f "$_TMP_F" ] && rm -f "$_TMP_F" && log_msg "INFO" "🧹 Purged stale /tmp fragment: $(basename "$_TMP_F")"
    done 2>/dev/null || true
done
log_msg "INFO" "🧹 /tmp cleanup scan complete."

# ── tar exclude flags ─────────────────────────────────────────────────────────
# IMPORTANT for bsdtar (macOS): --exclude flags MUST come BEFORE -czf
# --format=gnutar  → avoids pax format; pax cannot archive Unix domain sockets
# --no-xattrs      → skips macOS extended attributes (avoid "Operation not supported")
# --exclude="*.ipc" → skips Git fsmonitor socket files specifically
TAR_EXCLUDES=(
    # General dev/build artefacts
    --exclude=".DS_Store"           --exclude=".localized"
    --exclude="node_modules"        --exclude="bower_components"
    --exclude="vendor"
    # Laravel / framework cache
    --exclude="storage/debugbar"    --exclude="storage/clockwork"
    --exclude="storage/framework/views"
    --exclude="storage/framework/cache/data"
    --exclude="storage/framework/sessions"
    --exclude="storage/framework/testing"
    --exclude="storage/logs"
    # Android / Gradle
    --exclude="build/intermediates" --exclude="build/outputs"
    --exclude=".gradle/caches"
    # macOS system dirs (require Full Disk Access — skip them)
    --exclude="Library/Caches"       --exclude="Library/Logs"
    --exclude="Library/Application Support/MobileSync"
    --exclude="Library/Application Support/CallHistoryDB"
    --exclude="Library/Messages"
    --exclude="Library/Mail"
    # Archive files already on Drive
    --exclude="*.zip"      --exclude="*.tar.gz"  --exclude="*.tar"
    # Git pack files and sockets
    --exclude=".git/objects/pack"   --exclude="*.ipc"
    # Xcode / Apple developer caches
    --exclude="DerivedData"
    --exclude="*.xcarchive/dSYMs"
    --exclude="Pods"
    # Python / virtualenv
    --exclude="__pycache__"  --exclude="*.pyc"  --exclude=".venv"  --exclude="venv"
    # Photos Library — requires Full Disk Access; skip gracefully
    --exclude="*.photoslibrary"
    # Apple internal cache symlinks (.fcpcache is a self-referencing symlink
    # inside iMovie Library: .fcpcache -> . causes infinite recursion in zip/tar)
    --exclude=".fcpcache"
)

# Append any user-defined custom excludes from config [excludes] section
for CUSTOM_PAT in "${CUSTOM_EXCLUDES[@]}"; do
    TAR_EXCLUDES+=(--exclude="$CUSTOM_PAT")
done

# Compression flag: -1 (fast) through -9 (best). Default -6.
CLEVEL="${COMPRESSION_LEVEL:-6}"
[[ "$CLEVEL" =~ ^[1-9]$ ]] || CLEVEL=6
export GZIP="-${CLEVEL}"

# COPYFILE_DISABLE=1  — tells macOS to skip the AppleDouble ._* sidecar files
# that carry extended attributes. Without this, bsdtar may still attempt to
# pack xattrs on HFS+/APFS volumes and hit "Operation not permitted" for
# system-protected files even when --no-xattrs is passed.
export COPYFILE_DISABLE=1

# ==============================================================================
# FUNCTION: preflight_space_check
# ==============================================================================
preflight_space_check() {
    local SRC="$1" DEST_DIR="$2"
    log_msg "INFO" "   🔍 Pre-flight space check..."

    local RAW_KB
    RAW_KB=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}' | tr -cd '0-9')
    RAW_KB=$(( ${RAW_KB:-0} + 0 ))   # coerce to integer
    if [ "$RAW_KB" -eq 0 ]; then
        log_msg "WARN" "   ⚠️  Could not measure source size (permissions?). Skipping space check."
        return 0
    fi

    local EST_KB=$(( RAW_KB / 4 ))
    local RAW_MB=$(( RAW_KB / 1024 ))
    local EST_MB=$(( EST_KB / 1024 ))
    local REQUIRED_KB=$(( EST_KB + EST_KB / 10 ))

    local FREE_KB
    FREE_KB=$(df -k "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -cd '0-9')
    FREE_KB=$(( ${FREE_KB:-0} + 0 ))  # coerce to integer
    local FREE_MB=$(( FREE_KB / 1024 ))

    log_msg "INFO" "   Raw source:          ~${RAW_MB} MB"
    log_msg "INFO" "   Estimated archive:   ~${EST_MB} MB  (25% ratio + 10% buffer)"
    log_msg "INFO" "   Free on dest:        ~${FREE_MB} MB  ($DEST_DIR)"

    if [ -n "$FREE_KB" ] && [ "$REQUIRED_KB" -gt "$FREE_KB" ]; then
        log_err "SPACE CHECK FAILED: Need ~${EST_MB} MB, only ${FREE_MB} MB free on $DEST_DIR"
        return 1
    fi

    log_msg "INFO" "   ✅ Space check passed."
    ESTIMATED_SIZE_MB=$EST_MB
    return 0
}

# ==============================================================================
# FUNCTION: apply_retention_policy
# ==============================================================================
apply_retention_policy() {
    local DEST="$1" PREFIX="$2"
    # 3rd arg overrides global MAX_ARCHIVES_TO_KEEP (per-source retention)
    local KEEP_COUNT="${3:-$MAX_ARCHIVES_TO_KEEP}"
    KEEP_COUNT=$(( ${KEEP_COUNT:-0} + 0 ))
    [ "$KEEP_COUNT" -eq 0 ] && {
        log_msg "INFO" "   📁 Retention: disabled (keeping all)."
        return 0
    }

    local ALL_ARCHIVES COUNT
    # Match archives by sanitized label prefix — handles all archive formats
    local SAFE_PREFIX
    SAFE_PREFIX=$(echo "$PREFIX" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    # Gather all supported archive formats, newest first (ls -1t)
    # Do NOT pipe through sort -r — ls -1t already gives newest-first;
    # adding sort -r reverses to oldest-first and then head picks newest to prune (wrong).
    ALL_ARCHIVES=$(ls -1t "$DEST/${SAFE_PREFIX}_"*.tar.gz \
                         "$DEST/${SAFE_PREFIX}_"*.tar.bz2 \
                         "$DEST/${SAFE_PREFIX}_"*.tar.xz \
                         "$DEST/${SAFE_PREFIX}_"*.zip 2>/dev/null \
                   | grep -v "^ls:")
    # Strip non-digits; default to 0 to guard against "integer expected" errors
    COUNT=$(echo "$ALL_ARCHIVES" | grep -c '.' 2>/dev/null | tr -cd '0-9' | head -c 10)
    COUNT=$(( ${COUNT:-0} + 0 ))   # coerce to integer; also handles empty

    if [ "$COUNT" -le "$KEEP_COUNT" ]; then
        log_msg "INFO" "   📁 Retention: $COUNT archive(s) — within limit of $KEEP_COUNT."
        return 0
    fi

    local EXCESS=$(( COUNT - KEEP_COUNT ))
    log_msg "INFO" "   📁 Retention: pruning $EXCESS oldest (keeping $KEEP_COUNT)."
    # ALL_ARCHIVES is newest-first; tail picks the OLDEST $EXCESS to delete
    echo "$ALL_ARCHIVES" | tail -n "$EXCESS" | while IFS= read -r OLD_FILE; do
        rm -f "$OLD_FILE" && log_msg "INFO" "   🗑  Pruned: $(basename "$OLD_FILE")" \
                          || log_err "Failed to prune: $OLD_FILE"
    done
}

# ==============================================================================
# FUNCTION: incremental_manifest helpers
# Incremental backups use a per-source manifest file that records the timestamp
# of the last successful backup. On subsequent runs, only files modified since
# that timestamp are archived (using tar --newer-mtime).
#
# Manifest path: ~/.sourcestream/manifests/<safe_label>.manifest
# Contents: a single ISO-8601 date string written by date(1)
# ==============================================================================

# Returns the manifest file path for a given source label.
get_manifest_path() {
    local SRC_LABEL="$1"
    local SAFE
    SAFE=$(echo "$SRC_LABEL" | tr ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-60)
    echo "$MANIFEST_DIR/${SAFE}.manifest"
}

# Returns the mtime reference file path (a sentinel file whose mtime = last backup)
get_mtime_sentinel() {
    local SRC_LABEL="$1"
    local SAFE
    SAFE=$(echo "$SRC_LABEL" | tr ' ' '_' | tr -cd '[:alnum:]_-' | cut -c1-60)
    echo "$MANIFEST_DIR/${SAFE}.mtime"
}

# Write the sentinel file (touch it) to record now as the last backup time.
# Called AFTER a successful backup so the next incremental uses this mtime.
update_manifest() {
    local SRC_LABEL="$1"
    local SENTINEL
    SENTINEL=$(get_mtime_sentinel "$SRC_LABEL")
    touch "$SENTINEL" 2>/dev/null && \
        log_msg "INFO" "   📝 Incremental manifest updated: $(basename "$SENTINEL")" || \
        log_msg "WARN" "   ⚠️  Could not update incremental manifest."
    # Also write human-readable timestamp for the dashboard
    local MANIFEST
    MANIFEST=$(get_manifest_path "$SRC_LABEL")
    date +"%Y-%m-%d %H:%M:%S" > "$MANIFEST" 2>/dev/null || true
}

# Returns the number of files that changed since the last incremental backup.
# Used in dry-run and log reporting.
count_changed_files() {
    local SRC_PATH="$1" SRC_LABEL="$2"
    local SENTINEL
    SENTINEL=$(get_mtime_sentinel "$SRC_LABEL")
    if [ ! -f "$SENTINEL" ]; then
        # No sentinel → treat as full
        find "$SRC_PATH" -type f 2>/dev/null | wc -l | tr -d ' '
    else
        find "$SRC_PATH" -newer "$SENTINEL" -type f 2>/dev/null | wc -l | tr -d ' '
    fi
}

# ==============================================================================
# FUNCTION: process_backup
# ==============================================================================
process_backup() {
    local SRC_PATH="$1"
    local SRC_NAME="$2"
    local SRC_ENTRY="${3:-${SRC_PATH}|${SRC_NAME}}"   # full entry for per-source keep

    # Effective retention: use per-source override if present, else global
    local EFFECTIVE_KEEP
    EFFECTIVE_KEEP=$(get_source_keep "$SRC_ENTRY")
    EFFECTIVE_KEEP=$(( ${EFFECTIVE_KEEP:-0} + 0 ))

    log_msg "INFO" "──────────────────────────────────────────────────────────"
    log_msg "INFO" "📂 Source: $SRC_NAME  →  $SRC_PATH"
    log_msg "INFO" "   Retention: keep $EFFECTIVE_KEEP archive(s) for this source"

    # Validate source
    if [ ! -d "$SRC_PATH" ] && [ ! -L "$SRC_PATH" ]; then
        log_err "Source directory not found: $SRC_PATH"
        return 1
    fi

    local REAL_SRC
    REAL_SRC=$(cd "$SRC_PATH" && pwd -P 2>/dev/null)
    if [ -z "$REAL_SRC" ]; then
        log_err "Cannot resolve real path: $SRC_PATH (permissions?)"
        return 1
    fi
    log_msg "INFO" "   Real path: $REAL_SRC"

    # Validate destinations
    if [ "${#DEST_ENTRIES[@]}" -eq 0 ]; then
        log_err "No destinations configured. Cannot backup."
        return 1
    fi

    # Build archive filename — derived from source label (not hardcoded "Developer_Backup")
    local TAR_NAME
    TAR_NAME="$(make_archive_name "$SRC_NAME")"
    log_msg "INFO" "   Archive: $TAR_NAME"

    # Determine write strategy
    local DEST_COUNT="${#DEST_ENTRIES[@]}"
    local STAGE_PATH PRIMARY_DEST_PATH=""

    if [ "$DIRECT_TO_DRIVE" = "true" ] && [ "$DEST_COUNT" -eq 1 ]; then
        PRIMARY_DEST_PATH="${DEST_ENTRIES[0]%%|*}"
        local PRIMARY_LABEL="${DEST_ENTRIES[0]##*|}"
        mkdir -p "$PRIMARY_DEST_PATH" 2>>"$ERROR_LOG"
        preflight_space_check "$REAL_SRC" "$PRIMARY_DEST_PATH" || return 1
        STAGE_PATH="$PRIMARY_DEST_PATH/$TAR_NAME"
        log_msg "INFO" "   Mode: DIRECT → $PRIMARY_LABEL  (1× SSD peak — no /tmp staging)"
    else
        preflight_space_check "$REAL_SRC" "/tmp" || return 1
        STAGE_PATH="/tmp/$TAR_NAME"
        log_msg "INFO" "   Mode: STAGE via /tmp → $DEST_COUNT destinations"
    fi

    # Register with trap so partial archive is cleaned on crash
    _PARTIAL_FILES+=("$STAGE_PATH")

    # Set progress-tracking global BEFORE tar starts (server polls this)
    CURRENT_ARCHIVE_PATH="$STAGE_PATH"

    # Build merged exclude flags: global TAR_EXCLUDES + per-source excludes
    local MERGED_EXCLUDES=("${TAR_EXCLUDES[@]}")
    local _PER_SRC_FLAG
    while IFS= read -r _PER_SRC_FLAG; do
        [[ -n "$_PER_SRC_FLAG" ]] && MERGED_EXCLUDES+=("$_PER_SRC_FLAG")
    done < <(build_source_excludes "$SRC_PATH")
    log_msg "INFO" "   Excludes: ${#MERGED_EXCLUDES[@]} total flags (global + per-source)"

    # ── Incremental mode: determine --newer-mtime reference ────────────────────
    local INCR_FLAG=""
    local IS_INCREMENTAL=false
    if [ "${BACKUP_MODE:-full}" = "incremental" ]; then
        local SENTINEL
        SENTINEL=$(get_mtime_sentinel "$SRC_NAME")
        if [ -f "$SENTINEL" ]; then
            # Files modified after the sentinel's mtime will be archived
            INCR_FLAG="--newer-mtime=$(date -r "$SENTINEL" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)"
            IS_INCREMENTAL=true
            local CHANGED_FILES
            CHANGED_FILES=$(count_changed_files "$REAL_SRC" "$SRC_NAME")
            CHANGED_FILES=$(( ${CHANGED_FILES:-0} + 0 ))
            log_msg "INFO" "   Mode: INCREMENTAL — $CHANGED_FILES changed file(s) since last backup"
            if [ "$CHANGED_FILES" -eq 0 ]; then
                log_msg "INFO" "   ✅ No changes detected — skipping archive creation."
                update_manifest "$SRC_NAME"
                return 0
            fi
        else
            log_msg "INFO" "   Mode: INCREMENTAL (first run — full baseline backup)"
            IS_INCREMENTAL=true
        fi
    else
        log_msg "INFO" "   Mode: FULL backup"
    fi

    # ── Run tar/zip ────────────────────────────────────────────────────────────
    local ARCH_EXT; ARCH_EXT=$(get_archive_ext)
    log_msg "INFO" "⏳ Compressing [${ARCH_EXT}] → $STAGE_PATH"
    log_msg "INFO" "   (This may take several minutes for large source trees...)"

    # Pipe stderr through a filter:
    #   - "Operation not permitted" → demote to WARN (Photos Library, Mail, etc.)
    #   - "Could not pack extended attributes" → suppress (cosmetic, not an error)
    #   - everything else → pass through to ERROR_LOG
    local TAR_STDERR_TMP
    TAR_STDERR_TMP=$(mktemp /tmp/ss_tar_err.XXXXXX)
    local _COMP_FLAG; _COMP_FLAG=$(get_tar_comp_flag)

    if [ "$ARCH_EXT" = "zip" ]; then
        # zip format — uses zip(1); per-source excludes supported via -x flags
        # Build zip -x flags from MERGED_EXCLUDES (convert --exclude=PATTERN → -x "*PATTERN*")
        local ZIP_EXCL_FLAGS=()
        for _EXCL_FLAG in "${MERGED_EXCLUDES[@]}"; do
            # Strip "--exclude=" prefix
            local _PAT="${_EXCL_FLAG#--exclude=}"
            # Add leading/trailing glob for path segments if not already present
            [[ "$_PAT" == */* ]] || _PAT="*/${_PAT}/*"
            ZIP_EXCL_FLAGS+=("-x" "$_PAT")
        done

        # Incremental zip: collect only changed files via find -newer sentinel
        local INCR_ZIP_LIST=""
        if [ "$IS_INCREMENTAL" = "true" ] && [ -f "$(get_mtime_sentinel "$SRC_NAME")" ]; then
            local _SENT; _SENT=$(get_mtime_sentinel "$SRC_NAME")
            INCR_ZIP_LIST=$(mktemp /tmp/ss_zip_list.XXXXXX)
            (
                cd "$(dirname "$REAL_SRC")" || exit 1
                # -P: never follow symlinks — prevents .fcpcache -> . infinite loop
                find -P "$(basename "$REAL_SRC")" -newer "$_SENT" -type f 2>/dev/null \
                    | grep -v "\.DS_Store\|/node_modules/\|/__pycache__/\|\.photoslibrary/\|/\.fcpcache/" \
                    > "$INCR_ZIP_LIST"
            )
            local _ZIFC; _ZIFC=$(wc -l < "$INCR_ZIP_LIST" | tr -d ' ')
            log_msg "INFO" "   Incremental zip: $_ZIFC changed file(s)"
        fi

        (
            cd "$(dirname "$REAL_SRC")" || exit 1
            if [ -n "$INCR_ZIP_LIST" ] && [ -s "$INCR_ZIP_LIST" ]; then
                # -y: store symlinks as symlinks (prevents following .fcpcache -> . infinite loop)
                COPYFILE_DISABLE=1 zip -r -y -q -${CLEVEL} "$STAGE_PATH" \
                    -x "*.DS_Store" -x "*/node_modules/*" -x "*/.git/objects/pack/*" \
                    -x "*/__pycache__/*" -x "*.pyc" -x "*/DerivedData/*" \
                    -x "*.photoslibrary/*" -x "*/.venv/*" -x "*/venv/*" \
                    -x "*/.fcpcache" -x "*/.fcpcache/*" \
                    "${ZIP_EXCL_FLAGS[@]}" \
                    - < "$INCR_ZIP_LIST" \
                    2>"$TAR_STDERR_TMP"
            else
                # -y: store symlinks as symlinks (prevents following .fcpcache -> . infinite loop)
                COPYFILE_DISABLE=1 zip -r -y -q -${CLEVEL} "$STAGE_PATH" "$(basename "$REAL_SRC")" \
                    -x "*.DS_Store" -x "*/node_modules/*" -x "*/.git/objects/pack/*" \
                    -x "*/__pycache__/*" -x "*.pyc" -x "*/DerivedData/*" \
                    -x "*.photoslibrary/*" -x "*/.venv/*" -x "*/venv/*" \
                    -x "*/.fcpcache" -x "*/.fcpcache/*" \
                    "${ZIP_EXCL_FLAGS[@]}" \
                    2>"$TAR_STDERR_TMP"
            fi
        )
        [ -n "$INCR_ZIP_LIST" ] && rm -f "$INCR_ZIP_LIST"
    else
        # tar format (gzip / bzip2 / xz) — MERGED_EXCLUDES has global + per-source
        # For incremental tar: pass --newer-mtime="<sentinel-mtime>" to only archive changed files
        (
            cd "$(dirname "$REAL_SRC")" || exit 1
            COPYFILE_DISABLE=1 tar \
                "${MERGED_EXCLUDES[@]}" \
                --format=gnutar \
                --no-xattrs \
                ${INCR_FLAG:+"$INCR_FLAG"} \
                -c${_COMP_FLAG}f "$STAGE_PATH" \
                -h \
                "$(basename "$REAL_SRC")" \
                2>"$TAR_STDERR_TMP"
        )
    fi
    local TAR_EXIT=$?

    # Classify stderr lines
    if [ -s "$TAR_STDERR_TMP" ]; then
        local PERM_WARNS REAL_ERRORS
        PERM_WARNS=$(grep -c "Operation not permitted\|Could not pack extended attributes\|Couldn't visit directory" "$TAR_STDERR_TMP" 2>/dev/null || true)
        REAL_ERRORS=$(grep -v "Operation not permitted\|Could not pack extended attributes\|Couldn't visit directory\|Error exit delayed" "$TAR_STDERR_TMP" | grep -c '.' 2>/dev/null || true)
        # Coerce to integer
        PERM_WARNS=$(( ${PERM_WARNS:-0} + 0 ))
        REAL_ERRORS=$(( ${REAL_ERRORS:-0} + 0 ))
        if [ "$PERM_WARNS" -gt 0 ]; then
            log_msg "WARN" "   ⚠️  $PERM_WARNS path(s) skipped: 'Operation not permitted' (requires Full Disk Access for Photos/Mail/Messages). Continuing."
            # Show GUI dialog prompting user to grant Full Disk Access.
            # Run in background so it doesn't stall the backup process.
            (
                local _BTN
                _BTN=$(osascript -e \
                    "display dialog \"SourceStream could not access $PERM_WARNS protected file(s) during backup.\n\nTo allow full backups of Photos, Mail, Messages and other system folders:\n\n  1. Open System Settings\n  2. Go to Privacy & Security → Full Disk Access\n  3. Enable SourceStream (and Terminal if running manually)\n\nBackup completed with some files skipped.\" with title \"SourceStream — Full Disk Access Needed\" buttons {\"Open Privacy Settings\", \"OK\"} default button \"Open Privacy Settings\" with icon caution" \
                    2>/dev/null) || true
                if [ "${_BTN:-}" = "button returned:Open Privacy Settings" ]; then
                    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
                fi
            ) &
        fi
        if [ "$REAL_ERRORS" -gt 0 ]; then
            cat "$TAR_STDERR_TMP" >> "$ERROR_LOG"
        fi
    fi
    rm -f "$TAR_STDERR_TMP"

    # Exit 0 = clean. Exit 1 = files changed or permission skips (normal for live sources).
    # Exit 2+ = real failure (I/O error, out of space) — only fail if archive is empty.
    if [ "$TAR_EXIT" -eq 0 ]; then
        log_msg "INFO" "   ✅ tar completed cleanly (exit 0)."
    elif [ "$TAR_EXIT" -eq 1 ]; then
        local _TOOL; [ "$ARCH_EXT" = "zip" ] && _TOOL="zip" || _TOOL="tar"
        log_msg "WARN" "   ⚠️  $_TOOL exit 1: some files skipped (changed during run or permission-denied). Continuing..."
    else
        # Exit 2+: only abort if the archive is missing or empty
        if [ -f "$STAGE_PATH" ] && [ -s "$STAGE_PATH" ]; then
            log_msg "WARN" "   ⚠️  tar exit $TAR_EXIT but archive produced — treating as partial success."
        else
            log_err "tar failed (exit $TAR_EXIT) — see $ERROR_LOG for details"
            rm -f "$STAGE_PATH" 2>/dev/null
            return 1
        fi
    fi

    # Verify archive was produced
    if [ ! -f "$STAGE_PATH" ] || [ ! -s "$STAGE_PATH" ]; then
        log_err "No usable archive produced (missing or zero bytes): $STAGE_PATH"
        rm -f "$STAGE_PATH" 2>/dev/null
        return 1
    fi

    local ARCHIVE_SIZE
    ARCHIVE_SIZE=$(du -sh "$STAGE_PATH" | cut -f1)
    log_msg "INFO" "   📦 Archive size: $ARCHIVE_SIZE"

    # Auto-verify archive if BACKUP_VERIFY=true (format-aware via verify_archive)
    if [ "${BACKUP_VERIFY:-false}" = "true" ]; then
        log_msg "INFO" "   🔍 Auto-verifying archive integrity (${ARCH_EXT})..."
        if verify_archive "$STAGE_PATH" >/dev/null 2>>"$ERROR_LOG"; then
            log_msg "INFO" "   ✅ Archive verified OK."
        else
            log_err "Archive verify FAILED for $STAGE_PATH — may be corrupt!"
            rm -f "$STAGE_PATH" 2>/dev/null
            return 1
        fi
    fi

    # ── Distribute to all destinations ────────────────────────────────────────
    local OVERALL_SUCCESS=true

    for DEST_ENTRY in "${DEST_ENTRIES[@]}"; do
        local DEST_PATH="${DEST_ENTRY%%|*}"
        local DEST_LABEL="${DEST_ENTRY##*|}"

        if [ "$DEST_PATH" = "$PRIMARY_DEST_PATH" ]; then
            log_msg "SUCCESS" "☁️  Archive already at $DEST_LABEL (written directly)."
            apply_retention_policy "$DEST_PATH" "$SRC_NAME" "$EFFECTIVE_KEEP"
            continue
        fi

        if [ ! -d "$(dirname "$DEST_PATH")" ] && [ ! -d "$DEST_PATH" ]; then
            log_err "Destination not reachable: $DEST_LABEL ($DEST_PATH) — skipping."
            OVERALL_SUCCESS=false
            continue
        fi

        mkdir -p "$DEST_PATH" 2>>"$ERROR_LOG"
        log_msg "INFO" "🚚 Copying to $DEST_LABEL..."
        cp "$STAGE_PATH" "$DEST_PATH/" 2>>"$ERROR_LOG"
        local CP_EXIT=$?
        if [ "$CP_EXIT" -eq 0 ]; then
            log_msg "SUCCESS" "☁️  Copy to $DEST_LABEL succeeded."
            apply_retention_policy "$DEST_PATH" "$SRC_NAME" "$EFFECTIVE_KEEP"
        else
            log_err "Copy to $DEST_LABEL failed (exit $CP_EXIT)."
            OVERALL_SUCCESS=false
        fi
    done

    # Clean up /tmp staging copy if used
    if [ "$STAGE_PATH" = "/tmp/$TAR_NAME" ]; then
        if [ "$OVERALL_SUCCESS" = "true" ]; then
            rm -f "$STAGE_PATH"
            log_msg "INFO" "🧹 Staging copy purged from /tmp."
        else
            log_msg "WARN" "⚠️  Staging copy retained at $STAGE_PATH for manual recovery."
        fi
    fi

    # ── Upload to remote destinations (S3 / B2 / rclone) ─────────────────────
    # Always upload the final archive — from primary dest path if direct, else stage.
    if [ "${#REMOTE_DEST_ENTRIES[@]}" -gt 0 ]; then
        local UPLOAD_SRC
        # If STAGE_PATH was purged (direct mode), use primary dest copy
        if [ "$DIRECT_TO_DRIVE" = "true" ] && [ -n "$PRIMARY_DEST_PATH" ]; then
            UPLOAD_SRC="$PRIMARY_DEST_PATH/$TAR_NAME"
        else
            UPLOAD_SRC="$STAGE_PATH"
        fi
        if [ -f "$UPLOAD_SRC" ]; then
            for REMOTE_ENTRY in "${REMOTE_DEST_ENTRIES[@]}"; do
                local REMOTE_URI="${REMOTE_ENTRY%%|*}"
                local REMOTE_LABEL="${REMOTE_ENTRY##*|}"
                upload_to_remote "$UPLOAD_SRC" "$REMOTE_URI" "$REMOTE_LABEL" || \
                    log_msg "WARN" "   Remote upload to $REMOTE_LABEL failed — local backup still intact."
            done
        else
            log_msg "WARN" "   ⚠️  Remote upload skipped — archive not found at $UPLOAD_SRC"
        fi
    fi

    log_msg "SUCCESS" "✅ Backup complete: $SRC_NAME → $TAR_NAME"

    # Unregister STAGE_PATH from the EXIT trap — archive is complete and
    # must NOT be deleted. The trap only cleans up genuinely partial files
    # (i.e. those left behind by an unexpected crash before this point).
    local _new_partial=()
    for _pf in "${_PARTIAL_FILES[@]}"; do
        [ "$_pf" != "$STAGE_PATH" ] && _new_partial+=("$_pf")
    done
    _PARTIAL_FILES=("${_new_partial[@]}")

    # Update incremental manifest so the next run only archives changes since now
    update_manifest "$SRC_NAME"

    return 0
}

# ==============================================================================
# FUNCTION: write_status_json
# ==============================================================================
BACKUP_RUN_START_TS=""
BACKUP_SOURCES_JSON=""
BACKUP_ARCHIVES_JSON=""
BACKUP_DESTS_JSON=""

write_status_json() {
    local ENGINE_STATUS="$1"
    local NOW TS_HUMAN
    NOW=$(date +"%Y-%m-%d %H:%M:%S")
    TS_HUMAN="$NOW"

    local DURATION_MIN=0 RUN_END_TS=""
    if [ "$ENGINE_STATUS" != "running" ] && [ -n "$BACKUP_RUN_START_TS" ]; then
        RUN_END_TS="$NOW"
        local T_START T_END
        T_START=$(date -j -f "%Y-%m-%d %H:%M:%S" "$BACKUP_RUN_START_TS" +%s 2>/dev/null || echo 0)
        T_END=$(date +%s)
        DURATION_MIN=$(( (T_END - T_START) / 60 ))
    fi

    local CRON_EXPR NEXT_BACKUP
    CRON_EXPR=$(crontab -l 2>/dev/null | grep 'backup_engine\|sourcestream' | head -1 | awk '{print $1" "$2" "$3" "$4" "$5}' || echo "not set")
    NEXT_BACKUP=$(date -v+sun -v23H -v0M -v0S "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")

    local RECENT_LOG_JSON="[]"
    if [ -f "$OUTPUT_LOG" ]; then
        RECENT_LOG_JSON=$(tail -n 20 "$OUTPUT_LOG" 2>/dev/null | \
            sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | \
            awk 'BEGIN{print "["; first=1} {if(!first) printf ",\n"; printf "  \"%s\"", $0; first=0} END{print "\n]"}')
    fi

    local ERR_BYTES=0
    [ -f "$ERROR_LOG" ] && ERR_BYTES=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -cd '0-9' || true)
    ERR_BYTES=$(( ${ERR_BYTES:-0} + 0 ))

    local CUR_PID="null"
    local RUNNING_PID
    RUNNING_PID=$(pgrep -f 'backup_engine.sh' 2>/dev/null | grep -v "^$$" | head -1)
    [ -n "$RUNNING_PID" ] && CUR_PID="$RUNNING_PID"

    local LAST_STATUS
    LAST_STATUS=$(grep -E '(SUCCESS|ERROR)' "$OUTPUT_LOG" 2>/dev/null | tail -1 | \
        grep -oE '(SUCCESS|ERROR)' | head -1 || echo "UNKNOWN")

    local ARCHIVES_JSON="[]"
    [ -n "$BACKUP_ARCHIVES_JSON" ] && ARCHIVES_JSON="[$BACKUP_ARCHIVES_JSON]"
    local SOURCES_JSON="[]"
    [ -n "$BACKUP_SOURCES_JSON" ] && SOURCES_JSON="[$BACKUP_SOURCES_JSON]"
    local DESTS_JSON="[]"
    [ -n "$BACKUP_DESTS_JSON" ] && DESTS_JSON="[$BACKUP_DESTS_JSON]"

    cat > "$STATUS_JSON" << JSON
{
  "last_updated": "$TS_HUMAN",
  "engine_status": "$ENGINE_STATUS",
  "last_run_status": "$LAST_STATUS",
  "last_run_start": "$BACKUP_RUN_START_TS",
  "last_run_end": "$RUN_END_TS",
  "last_run_duration_min": $DURATION_MIN,
  "current_archive_path": "$CURRENT_ARCHIVE_PATH",
  "estimated_size_mb": $ESTIMATED_SIZE_MB,
  "sources": $SOURCES_JSON,
  "destinations": $DESTS_JSON,
  "archives": $ARCHIVES_JSON,
  "cron_schedule": "$CRON_EXPR",
  "next_backup": "$NEXT_BACKUP",
  "direct_to_drive": $DIRECT_TO_DRIVE,
  "max_archives_to_keep": $MAX_ARCHIVES_TO_KEEP,
  "ssd_footprint_mode": "$([ "$DIRECT_TO_DRIVE" = "true" ] && echo '1x (Direct)' || echo '2x (Staging)')",
  "recent_log": $RECENT_LOG_JSON,
  "error_log_bytes": $ERR_BYTES,
  "pid": $CUR_PID
}
JSON
}

collect_source_json() {
    local SRC_NAME="$1" SRC_PATH="$2" RAW_MB="$3" ARCHIVE_MB="$4" SRC_STATUS="$5"
    local ENTRY
    ENTRY="{\"name\":\"$SRC_NAME\",\"path\":\"$SRC_PATH\",\"raw_mb\":$RAW_MB,\"archive_mb\":$ARCHIVE_MB,\"status\":\"$SRC_STATUS\"}"
    [ -n "$BACKUP_SOURCES_JSON" ] && BACKUP_SOURCES_JSON="$BACKUP_SOURCES_JSON,"
    BACKUP_SOURCES_JSON="$BACKUP_SOURCES_JSON$ENTRY"
}

collect_dest_json() {
    local LABEL="$1" PATH_VAL="$2" DEST_STATUS="$3"
    local ARCHIVE_CNT FREE_MB TOTAL_USED_MB
    ARCHIVE_CNT=$(ls "$PATH_VAL/"*.tar.gz "$PATH_VAL/"*.tar.bz2 "$PATH_VAL/"*.tar.xz "$PATH_VAL/"*.zip 2>/dev/null | grep -v "^ls:" | wc -l | tr -d ' ')
    FREE_MB=$(df -k "$PATH_VAL" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
    TOTAL_USED_MB=$(du -sm "$PATH_VAL" 2>/dev/null | awk '{print $1}')
    local ENTRY
    ENTRY="{\"label\":\"$LABEL\",\"path\":\"$PATH_VAL\",\"archive_count\":${ARCHIVE_CNT:-0},\"total_mb\":${TOTAL_USED_MB:-0},\"free_mb\":${FREE_MB:-0},\"status\":\"$DEST_STATUS\"}"
    [ -n "$BACKUP_DESTS_JSON" ] && BACKUP_DESTS_JSON="$BACKUP_DESTS_JSON,"
    BACKUP_DESTS_JSON="$BACKUP_DESTS_JSON$ENTRY"
}

collect_archives_json() {
    local DEST_PATH="$1" DEST_LABEL="$2"
    while IFS= read -r fpath; do
        [ -z "$fpath" ] && continue
        local fname size_mb created
        fname=$(basename "$fpath")
        size_mb=$(du -sm "$fpath" 2>/dev/null | awk '{print $1}')
        created=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$fpath" 2>/dev/null || echo "")
        local ENTRY
        ENTRY="{\"name\":\"$fname\",\"size_mb\":${size_mb:-0},\"destination\":\"$DEST_LABEL\",\"created\":\"$created\"}"
        [ -n "$BACKUP_ARCHIVES_JSON" ] && BACKUP_ARCHIVES_JSON="$BACKUP_ARCHIVES_JSON,"
        BACKUP_ARCHIVES_JSON="$BACKUP_ARCHIVES_JSON$ENTRY"
    done < <(ls -1t "$DEST_PATH/"*.tar.gz "$DEST_PATH/"*.tar.bz2 "$DEST_PATH/"*.tar.xz "$DEST_PATH/"*.zip 2>/dev/null | grep -v "^ls:")
}

# ==============================================================================
# MAIN
# ==============================================================================

# ── Single-source override (from /api/run-backup with source_path body param) ──
# When server.py sets SS_SINGLE_SOURCE, filter SOURCE_ENTRIES to only that path
if [ -n "$SS_SINGLE_SOURCE" ]; then
    FILTERED=()
    for E in "${SOURCE_ENTRIES[@]}"; do
        [[ "${E%%|*}" == "$SS_SINGLE_SOURCE" ]] && FILTERED+=("$E")
    done
    if [ "${#FILTERED[@]}" -gt 0 ]; then
        SOURCE_ENTRIES=("${FILTERED[@]}")
        log_msg "INFO" "🎯 Single-source mode: $(echo "${SOURCE_ENTRIES[0]#*|}" | cut -d'|' -f1) ($SS_SINGLE_SOURCE)"
    else
        log_msg "WARN" "⚠️  SS_SINGLE_SOURCE='$SS_SINGLE_SOURCE' not found in config — running all sources."
    fi
fi

BACKUP_RUN_START_TS=$(date +"%Y-%m-%d %H:%M:%S")
write_status_json "running"

MAIN_OVERALL_STATUS="SUCCESS"

if [ "${#SOURCE_ENTRIES[@]}" -eq 0 ]; then
    log_err "No sources configured. Add sources via SourceStream Dashboard → Settings."
    MAIN_OVERALL_STATUS="ERROR"
else
    for SRC_ENTRY in "${SOURCE_ENTRIES[@]}"; do
        SRC_PATH="${SRC_ENTRY%%|*}"
        SRC_NAME="${SRC_ENTRY#*|}"; SRC_NAME="${SRC_NAME%%|*}"
        if process_backup "$SRC_PATH" "$SRC_NAME" "$SRC_ENTRY"; then
            RAW_MB=$(du -sm "$SRC_PATH" 2>/dev/null | awk '{print $1}')
            collect_source_json "$SRC_NAME" "$SRC_PATH" "${RAW_MB:-0}" "0" "SUCCESS"
        else
            collect_source_json "$SRC_NAME" "$SRC_PATH" "0" "0" "ERROR"
            MAIN_OVERALL_STATUS="ERROR"
        fi
    done
fi

for DEST_ENTRY in "${DEST_ENTRIES[@]}"; do
    DEST_PATH="${DEST_ENTRY%%|*}"
    DEST_LABEL="${DEST_ENTRY##*|}"
    if [ -d "$DEST_PATH" ]; then
        collect_dest_json "$DEST_LABEL" "$DEST_PATH" "online"
        collect_archives_json "$DEST_PATH" "$DEST_LABEL"
    else
        collect_dest_json "$DEST_LABEL" "$DEST_PATH" "offline"
    fi
done

log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_msg "SUCCESS" "🎉 SourceStream backup engine concluded. Trace: $OUTPUT_LOG"
log_msg "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

write_status_json "$MAIN_OVERALL_STATUS"
log_msg "INFO" "📊 Status written → $STATUS_JSON"

# ── macOS notification on cron completion ─────────────────────────────────────
if [ "${NOTIFY_ON_COMPLETE:-false}" = "true" ]; then
    if [ "$MAIN_OVERALL_STATUS" = "SUCCESS" ]; then
        NOTIF_MSG="✅ Backup finished successfully."
    else
        NOTIF_MSG="⚠️ Backup finished with errors — check the error log."
    fi
    osascript -e "display notification \"$NOTIF_MSG\" with title \"SourceStream\" sound name \"Glass\"" 2>/dev/null || true
fi
