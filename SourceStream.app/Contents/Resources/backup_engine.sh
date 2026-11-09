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
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Progress-tracking globals (written to status.json)
CURRENT_ARCHIVE_PATH=""    # set before tar starts
ESTIMATED_SIZE_MB=0        # set by preflight_space_check

mkdir -p "$LOG_DIR" "$SS_DIR/config"

# ── Logging ───────────────────────────────────────────────────────────────────
log_msg() {
    local TYPE="$1" MSG="$2" TS
    TS=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TS] $TYPE: $MSG" | tee -a "$OUTPUT_LOG"
}
log_err() {
    local MSG="$1" TS
    TS=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TS] ERROR: $MSG" | tee -a "$ERROR_LOG" -a "$OUTPUT_LOG"
}

# ── Defaults ──────────────────────────────────────────────────────────────────
DIRECT_TO_DRIVE="true"
MAX_ARCHIVES_TO_KEEP=3
COMPRESSION_LEVEL=6          # gzip 1(fast)–9(best), default 6
ARCHIVE_PREFIX="{label}"     # archive name template: {label}, {hostname}, {date}
HOSTNAME_IN_NAME="false"
SOURCE_ENTRIES=()
DEST_ENTRIES=()
CUSTOM_EXCLUDES=()

# ── Auto-detect Google Drive path (any user, any Google account) ───────────────
detect_gdrive() {
    local cs="$HOME/Library/CloudStorage"
    if [ -d "$cs" ]; then
        # Pick first GoogleDrive-* folder found (handles any email address)
        local d
        for d in "$cs"/GoogleDrive-*/; do
            [ -d "${d}My Drive" ] && { echo "${d}My Drive/Developer Backups"; return; }
        done
    fi
    # Legacy Google Drive location
    for d in "$HOME/Google Drive/My Drive" "$HOME/Google Drive"; do
        [ -d "$d" ] && { echo "$d/Developer Backups"; return; }
    done
    # Fallback — user will configure via Dashboard
    echo "$HOME/Library/CloudStorage/GoogleDrive/My Drive/Developer Backups"
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
    [ ! -f "$CONF_FILE" ] && return
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue

        if [[ "$trimmed" =~ ^\[([a-zA-Z_]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
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
                    esac
                fi
                ;;
            sources)      [[ "$trimmed" == *"|"* ]] && SOURCE_ENTRIES+=("$trimmed") ;;
            destinations) [[ "$trimmed" == *"|"* ]] && DEST_ENTRIES+=("$trimmed") ;;
            excludes)     [[ -n "$trimmed" ]] && CUSTOM_EXCLUDES+=("$trimmed") ;;
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

    local TEMPLATE="${ARCHIVE_PREFIX:-{label}}"
    local NAME="$TEMPLATE"
    NAME="${NAME//\{label\}/$SAFE_LABEL}"
    NAME="${NAME//\{hostname\}/$HOSTNAME_SHORT}"
    NAME="${NAME//\{date\}/$DATE_PART}"
    NAME="${NAME//\{time\}/$TIME_PART}"

    # Always append timestamp suffix so archives never overwrite each other
    echo "${NAME}_${DATE_PART}_${TIME_PART}.tar.gz"
}

# ── Flush leftover /tmp fragments from aborted sessions ───────────────────────
rm -f /tmp/*.tar.gz 2>/dev/null
log_msg "INFO" "🧹 /tmp cleanup scan complete."

# ── tar exclude flags ─────────────────────────────────────────────────────────
# IMPORTANT for bsdtar (macOS): --exclude flags MUST come BEFORE -czf
# --format=gnutar  → avoids pax format; pax cannot archive Unix domain sockets
# --no-xattrs      → skips macOS extended attributes (avoid "Operation not supported")
# --exclude="*.ipc" → skips Git fsmonitor socket files specifically
TAR_EXCLUDES=(
    --exclude=".DS_Store"      --exclude=".localized"
    --exclude="node_modules"   --exclude="bower_components"
    --exclude="vendor"         --exclude="storage/debugbar"
    --exclude="storage/clockwork"
    --exclude="storage/framework/views"
    --exclude="storage/framework/cache/data"
    --exclude="storage/framework/sessions"
    --exclude="storage/framework/testing"
    --exclude="storage/logs"
    --exclude="build/intermediates" --exclude="build/outputs"
    --exclude=".gradle/caches"      --exclude="Library/Caches"
    --exclude="Library/Logs"        --exclude="*.zip"
    --exclude="*.tar.gz"            --exclude="*.tar"
    --exclude=".git/objects/pack"   --exclude="*.ipc"
)

# Append any user-defined custom excludes from config [excludes] section
for CUSTOM_PAT in "${CUSTOM_EXCLUDES[@]}"; do
    TAR_EXCLUDES+=(--exclude="$CUSTOM_PAT")
done

# Compression flag: -1 (fast) through -9 (best). Default -6.
CLEVEL="${COMPRESSION_LEVEL:-6}"
[[ "$CLEVEL" =~ ^[1-9]$ ]] || CLEVEL=6
export GZIP="-${CLEVEL}"

# ==============================================================================
# FUNCTION: preflight_space_check
# ==============================================================================
preflight_space_check() {
    local SRC="$1" DEST_DIR="$2"
    log_msg "INFO" "   🔍 Pre-flight space check..."

    local RAW_KB
    RAW_KB=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}')
    if [ -z "$RAW_KB" ] || [ "$RAW_KB" -eq 0 ]; then
        log_msg "WARN" "   ⚠️  Could not measure source size. Skipping space check."
        return 0
    fi

    local EST_KB=$(( RAW_KB / 4 ))
    local RAW_MB=$(( RAW_KB / 1024 ))
    local EST_MB=$(( EST_KB / 1024 ))
    local REQUIRED_KB=$(( EST_KB + EST_KB / 10 ))

    local FREE_KB
    FREE_KB=$(df -k "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
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
    [ "$MAX_ARCHIVES_TO_KEEP" -eq 0 ] && {
        log_msg "INFO" "   📁 Retention: disabled (keeping all)."
        return 0
    }

    local ALL_ARCHIVES COUNT
    # Match archives by sanitized label prefix — handles any naming scheme
    local SAFE_PREFIX
    SAFE_PREFIX=$(echo "$PREFIX" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    ALL_ARCHIVES=$(ls -1t "$DEST/"*.tar.gz 2>/dev/null \
        | grep "/${SAFE_PREFIX}_" \
        | sort -t_ -k2,3)
    COUNT=$(echo "$ALL_ARCHIVES" | grep -c '.tar.gz' 2>/dev/null || echo 0)

    if [ "$COUNT" -le "$MAX_ARCHIVES_TO_KEEP" ]; then
        log_msg "INFO" "   📁 Retention: $COUNT archive(s) — within limit of $MAX_ARCHIVES_TO_KEEP."
        return 0
    fi

    local EXCESS=$(( COUNT - MAX_ARCHIVES_TO_KEEP ))
    log_msg "INFO" "   📁 Retention: pruning $EXCESS oldest (keeping $MAX_ARCHIVES_TO_KEEP)."
    echo "$ALL_ARCHIVES" | head -n "$EXCESS" | while IFS= read -r OLD_FILE; do
        rm -f "$OLD_FILE" && log_msg "INFO" "   🗑  Pruned: $(basename "$OLD_FILE")" \
                          || log_err "Failed to prune: $OLD_FILE"
    done
}

# ==============================================================================
# FUNCTION: process_backup
# ==============================================================================
process_backup() {
    local SRC_PATH="$1"
    local SRC_NAME="$2"

    log_msg "INFO" "──────────────────────────────────────────────────────────"
    log_msg "INFO" "📂 Source: $SRC_NAME  →  $SRC_PATH"

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

    # Set progress-tracking global BEFORE tar starts (server polls this)
    CURRENT_ARCHIVE_PATH="$STAGE_PATH"

    # ── Run tar ────────────────────────────────────────────────────────────────
    log_msg "INFO" "⏳ Compressing → $STAGE_PATH"
    log_msg "INFO" "   (This may take several minutes for large source trees...)"

    (
        cd "$(dirname "$REAL_SRC")" || exit 1
        tar \
            "${TAR_EXCLUDES[@]}" \
            --format=gnutar \
            --no-xattrs \
            -czf "$STAGE_PATH" \
            -h \
            "$(basename "$REAL_SRC")" \
            2>>"$ERROR_LOG"
    )
    local TAR_EXIT=$?

    # Exit 0 = clean. Exit 1 = files changed during archiving (normal, not an error).
    # Exit 2+ = real failure (I/O error, out of space, permission denied).
    if [ "$TAR_EXIT" -eq 0 ]; then
        log_msg "INFO" "   ✅ tar completed cleanly (exit 0)."
    elif [ "$TAR_EXIT" -eq 1 ]; then
        log_msg "WARN" "   ⚠️  tar exit 1: files changed during archiving (normal for live repos). Continuing..."
    else
        log_err "tar failed (exit $TAR_EXIT) — see $ERROR_LOG for details"
        rm -f "$STAGE_PATH" 2>/dev/null
        return 1
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

    # ── Distribute to all destinations ────────────────────────────────────────
    local OVERALL_SUCCESS=true

    for DEST_ENTRY in "${DEST_ENTRIES[@]}"; do
        local DEST_PATH="${DEST_ENTRY%%|*}"
        local DEST_LABEL="${DEST_ENTRY##*|}"

        if [ "$DEST_PATH" = "$PRIMARY_DEST_PATH" ]; then
            log_msg "SUCCESS" "☁️  Archive already at $DEST_LABEL (written directly)."
            apply_retention_policy "$DEST_PATH" "$SRC_NAME"
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
            apply_retention_policy "$DEST_PATH" "$SRC_NAME"
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

    log_msg "SUCCESS" "✅ Backup complete: $SRC_NAME → $TAR_NAME"
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
    [ -f "$ERROR_LOG" ] && ERR_BYTES=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d ' ' || echo 0)

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
    ARCHIVE_CNT=$(ls "$PATH_VAL/"*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
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
    done < <(ls -1t "$DEST_PATH/"*.tar.gz 2>/dev/null)
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
        log_msg "INFO" "🎯 Single-source mode: ${SOURCE_ENTRIES[0]##*|} ($SS_SINGLE_SOURCE)"
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
        SRC_NAME="${SRC_ENTRY##*|}"
        if process_backup "$SRC_PATH" "$SRC_NAME"; then
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

