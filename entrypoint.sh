#!/bin/bash
set -e

# Alpine Toolbox Entrypoint
# - Validates PUID/PGID (allow 0 for root, otherwise 1000–6000)
# - Creates/locates the requested user/group
# - Runs init scripts once, or schedules scripts via cron
# - Ensures cron jobs run as the configured user when non-root
# - Provides LOG_LEVEL-driven output with progress for scripts (init and cron)

# Validate PUID/PGID (allow 0 for root, otherwise 1000–6000 inclusive)
validate_ids() {
    local uid=${PUID:-0}
    local gid=${PGID:-0}

    # Ensure numeric values
    if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
        echo "Invalid PUID: '$uid' (must be an integer between 1000 and 6000)" >&2
        exit 1
    fi
    if ! [[ "$gid" =~ ^[0-9]+$ ]]; then
        echo "Invalid PGID: '$gid' (must be an integer between 1000 and 6000)" >&2
        exit 1
    fi

    # Allow root when both are 0
    if [ "$uid" = "0" ] && [ "$gid" = "0" ]; then
        return 0
    fi

    # Enforce range otherwise
    if [ "$uid" -lt 1000 ] || [ "$uid" -gt 6000 ]; then
        echo "PUID out of range: $uid (must be 0 or between 1000 and 6000)" >&2
        exit 1
    fi
    if [ "$gid" -lt 1000 ] || [ "$gid" -gt 6000 ]; then
        echo "PGID out of range: $gid (must be 0 or between 1000 and 6000)" >&2
        exit 1
    fi
}

# Enforce PUID/PGID constraints before any user/group operations
validate_ids

# Logging helpers (levels: ERROR < WARN < INFORMATIONAL < VERBOSE < DEBUG)
normalize_level() {
    local raw="${1:-${LOG_LEVEL:-INFORMATIONAL}}"
    local uc
    uc=$(printf "%s" "$raw" | tr '[:lower:]' '[:upper:]')
    if [ "$uc" = "INFO" ] || [ "$uc" = "INFORMATIONAL" ]; then
        echo "INFORMATIONAL"
    elif [ "$uc" = "WARNING" ]; then
        echo "WARN"
    else
        echo "$uc"
    fi
}

level_value() {
    case "$(normalize_level "$1")" in
        DEBUG) echo 4 ;;
        VERBOSE) echo 3 ;;
        INFORMATIONAL) echo 2 ;;
        WARN) echo 1 ;;
        ERROR) echo 0 ;;
        *) echo 2 ;;
    esac
}

should_log() {
    local desired="$1"
    local current_val
    local desired_val
    current_val=$(level_value "${LOG_LEVEL:-INFORMATIONAL}")
    desired_val=$(level_value "$desired")
    [ "$current_val" -ge "$desired_val" ]
}

log() {
    local level="$1"; shift
    if should_log "$level"; then
        local tag
        tag=$(normalize_level "$level")
        echo "[$tag] $*"
    fi
}

log_error() { log ERROR "$@"; }
log_warn() { log WARN "$@"; }
log_info() { log INFORMATIONAL "$@"; }
log_verbose() { log VERBOSE "$@"; }
log_debug() { log DEBUG "$@"; }

# Create a script runner that respects LOG_LEVEL and prints progress
create_runner() {
    cat > /usr/local/bin/run_script.sh << 'EOS'
#!/bin/sh

# Usage: run_script.sh /path/to/script [script_name]
script_path="$1"
script_name="${2:-$(basename "$script_path")}"

# Normalize log level (case-insensitive)
# Accepted values:
# - DEBUG (stream script output)
# - VERBOSE (1s heartbeat, start/finish messages)
# - INFO or INFORMATIONAL (5s heartbeat)
level_raw="${LOG_LEVEL:-INFORMATIONAL}"
level_uc=$(printf "%s" "$level_raw" | tr '[:lower:]' '[:upper:]')

# Map shorthand/longform
if [ "$level_uc" = "INFO" ] || [ "$level_uc" = "INFORMATIONAL" ]; then
    level_uc="INFORMATIONAL"
fi

if [ "$level_uc" = "DEBUG" ]; then
    exec "$script_path"
fi

# Choose heartbeat interval based on level
heartbeat=5
if [ "$level_uc" = "VERBOSE" ]; then
    heartbeat=1
    echo "[VERBOSE] $script_name: starting"
fi

"$script_path" >/dev/null 2>&1 &
child_pid=$!
percent=0
while kill -0 "$child_pid" 2>/dev/null; do
    percent=$((percent + 100 / (60 / heartbeat)))
    if [ $percent -ge 95 ]; then
        percent=95
    fi
    echo "[INFORMATIONAL] $script_name: ${percent}% complete"
    sleep $heartbeat
done
wait "$child_pid"
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "[INFORMATIONAL] $script_name: 100% complete"
    if [ "$level_uc" = "VERBOSE" ]; then
        echo "[VERBOSE] $script_name: finished"
    fi
    exit 0
else
    echo "[ERROR] $script_name: failed with exit code $exit_code" >&2
    exit "$exit_code"
fi
EOS
    chmod +x /usr/local/bin/run_script.sh
}

# Ensure runner exists before any script execution
create_runner

# Create or select the runtime user/group based on PUID/PGID
create_user() {
    local uid=${PUID:-0}
    local gid=${PGID:-0}
    local username=""
    local groupname=""
    
    # Short-circuit for root
    if [ "$uid" = "0" ] && [ "$gid" = "0" ]; then
        log_debug "UID and GID are 0 (root) - using root user directly"
        export CONTAINER_USER="root"
        return 0
    fi

    # Resolve or create the group
    if [ "$gid" != "0" ]; then
        groupname=$(getent group $gid | cut -d: -f1 2>/dev/null)
        if [ -n "$groupname" ]; then
            log_info "Found existing group '$groupname' with GID: $gid"
        else
            log_info "No existing group found with GID: $gid, creating new group"
            groupname="customgroup"
            addgroup -g $gid $groupname
        fi
    else
        groupname="root"
        log_info "Using root group (GID: 0)"
    fi
    
    # Resolve or create the user
    username=$(getent passwd $uid | cut -d: -f1 2>/dev/null)
    if [ -n "$username" ]; then
        log_info "Found existing user '$username' with UID: $uid"
        # Update user's group if needed (non-root only)
        if [ "$gid" != "0" ] && [ "$groupname" != "root" ]; then
            usermod -g $groupname $username 2>/dev/null || true
        fi
    else
        log_info "No existing user found with UID: $uid, creating new user"
        username="customuser"
        
        # Create user with the specified UID and group
        adduser -u $uid -G $groupname -D $username
    fi
    
    # Export the username for downstream functions
    export CONTAINER_USER=$username
    log_info "Using user: $username (UID: $uid, GID: $gid)"
}

# Discover scripts and print startup information
print_startup_info() {
    local mode_label="init"
    if [ "${CRON:-false}" = "true" ]; then
        mode_label="cron"
    elif [ $# -gt 0 ] && [ "$1" != "sh" ]; then
        mode_label="command"
    fi

    local kernel
    kernel=$(uname -r 2>/dev/null || uname -a 2>/dev/null || echo "unknown")

    # Show requested IDs from environment (user may not be created yet)
    local uid_val="${PUID:-0}"
    local gid_val="${PGID:-0}"

    # Normalize LOG_LEVEL display
    local ll_raw="${LOG_LEVEL:-INFORMATIONAL}"
    local ll_uc
    ll_uc=$(printf "%s" "$ll_raw" | tr '[:lower:]' '[:upper:]')
    if [ "$ll_uc" = "INFO" ] || [ "$ll_uc" = "INFORMATIONAL" ]; then
        ll_uc="INFORMATIONAL"
    fi

    # Scan for scripts
    local script_dirs=("/scripts" "/init" "/cron-scripts")
    local total_scripts=0
    local found_dirs=""
    for dir in "${script_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local count
            count=$(find -L "$dir" -maxdepth 1 -type f -executable -name "*.sh" | wc -l | tr -d ' ')
            if [ "$count" != "0" ]; then
                total_scripts=$((total_scripts + count))
                if [ -z "$found_dirs" ]; then
                    found_dirs="$dir($count)"
                else
                    found_dirs="$found_dirs, $dir($count)"
                fi
            fi
        fi
    done
    if [ -z "$found_dirs" ]; then
        found_dirs="none"
    fi

    # Cron schedule context
    local cron_ctx="n/a"
    if [ "$mode_label" = "cron" ]; then
        if [ -f "/cron-schedule" ]; then
            cron_ctx="custom file: /cron-schedule"
        else
            cron_ctx="env CRON_SCHEDULE: ${CRON_SCHEDULE:-0 0 * * *}"
        fi
    fi

    # Get current timestamp in the configured timezone
    local startup_time
    startup_time=$(date '+%Y-%m-%d %H:%M:%S %Z')

    echo "== Alpine Toolbox Startup =="
    echo "Kernel: $kernel"
    echo "Mode: $mode_label"
    echo "User ID: $uid_val"
    echo "Group ID: $gid_val"
    echo "Timezone: ${TZ:-UTC}"
    echo "Startup time: $startup_time"
    echo "Log level: $ll_uc"
    echo "Script directories: $found_dirs (total: $total_scripts)"
    if [ "$mode_label" = "cron" ]; then
        echo "Cron source: $cron_ctx"
    fi
    echo "============================="
}

# Execute scripts in init mode (one-shot)
execute_init_scripts() {
    local script_dirs=("/scripts" "/init" "/cron-scripts")
    local scripts_found=false
    
    for dir in "${script_dirs[@]}"; do
        if [ -d "$dir" ]; then
            log_info "Found scripts directory: $dir"
            scripts_found=true
            
            # Execute all executable .sh files in the directory
            find -L "$dir" -maxdepth 1 -type f -executable -name "*.sh" | while read -r script; do
                script_name=$(basename "$script")
                # Use stable directory path instead of resolved symlink path
                script_path="$dir/$script_name"
                log_info "Executing init script: $script_name"
                
                # Execute script as the configured user with unbuffered output
                log_verbose "Executing: $script_path"
                if [ "${CONTAINER_USER:-appuser}" = "root" ]; then
                    # Run directly as root via runner
                    if /usr/local/bin/run_script.sh "$script_path" "$script_name"; then
                        log_info "✅ $script_name completed successfully"
                    else
                        log_error "❌ $script_name failed with exit code $?"
                        exit 1
                    fi
                else
                    # Run via su-exec for non-root users (using runner)
                    if su-exec ${CONTAINER_USER:-appuser} /usr/local/bin/run_script.sh "$script_path" "$script_name"; then
                        log_info "✅ $script_name completed successfully"
                    else
                        log_error "❌ $script_name failed with exit code $?"
                        exit 1
                    fi
                fi
            done
        fi
    done
    
    if [ "$scripts_found" = false ]; then
        log_warn "No scripts directories found. Container will exit."
    fi
}

# Generate cron jobs from discovered scripts or a custom schedule file
setup_cron_jobs() {
    local script_dirs=("/scripts" "/init" "/cron-scripts")
    local cron_schedule="${CRON_SCHEDULE:-0 0 * * *}"  # Default: daily at midnight
    local scripts_found=false
    
    # Use a custom schedule file if present
    if [ -f "/cron-schedule" ]; then
        log_info "Using custom cron schedule from /cron-schedule"
        # Custom schedule lines are used as-is. To run as a specific user,
        # include 'su-exec <user> <cmd>' in the schedule file explicitly.
        cp /cron-schedule /tmp/crontabs/root
        scripts_found=true
    else
        # Create cron jobs from discovered scripts
        for dir in "${script_dirs[@]}"; do
            if [ -d "$dir" ]; then
                log_info "Found scripts directory: $dir"
                scripts_found=true
                
                # Look for executable scripts
                # Use basename to get just the filename, then reconstruct stable path
                find -L "$dir" -maxdepth 1 -type f -executable -name "*.sh" | while read -r script; do
                    script_name=$(basename "$script")
                    # Use stable directory path instead of resolved symlink path
                    script_path="$dir/$script_name"
                    log_info "Setting up cron job for: $script_name (schedule: $cron_schedule)"
                    
                    # Create cron entry via runner; run as the configured user when non-root
                    # Note: Redirection must be outside su-exec to work properly
                    if [ "${CONTAINER_USER:-appuser}" != "root" ]; then
                        echo "$cron_schedule su-exec ${CONTAINER_USER:-appuser} /usr/local/bin/run_script.sh $script_path $script_name >> /proc/1/fd/1 2>&1" >> /tmp/crontabs/root
                    else
                        echo "$cron_schedule /usr/local/bin/run_script.sh $script_path $script_name >> /proc/1/fd/1 2>&1" >> /tmp/crontabs/root
                    fi
                done
            fi
        done
    fi
    
    if [ "$scripts_found" = false ]; then
        log_warn "No scripts directories found. No cron jobs will be created."
    fi
}

# Print startup context first (header comes before any user/group messages)
print_startup_info "$@"

# Create or select user with the specified UID/GID (messages follow header)
log_info "Creating user with UID: ${PUID:-0}, GID: ${PGID:-0}"
create_user

# Ensure crontabs directory exists
mkdir -p /tmp/crontabs

# Dispatch based on CRON environment variable or provided command arguments
if [ "${CRON:-false}" = "true" ]; then
    log_info "CRON mode enabled - setting up cron jobs and running persistently"
    
    # Setup cron jobs
    setup_cron_jobs
    
    # Set proper permissions on crontab file (crond requires 0600)
    if [ -f "/tmp/crontabs/root" ]; then
        chmod 0600 /tmp/crontabs/root
    fi
    
    # Start crond in the background (minimal logging)
    log_info "Starting crond..."
    crond -f -l 2 -c /tmp/crontabs &
    CROND_PID=$!
    
    # Wait briefly for crond to start
    sleep 1
    
    # Check that crond is running
    if ! kill -0 $CROND_PID 2>/dev/null; then
        log_warn "crond failed to start"
    else
        log_info "crond started successfully (PID: $CROND_PID)"
    fi
    
    # Check if we have cron jobs
    if [ -f "/tmp/crontabs/root" ] && [ -s "/tmp/crontabs/root" ]; then
        log_info "Cron jobs detected - keeping container running..."
        if should_log "DEBUG"; then
            log_debug "Cron jobs:"
            while IFS= read -r line; do
                log_debug "  $line"
            done < /tmp/crontabs/root
        fi
        log_info "Container will run indefinitely for cron jobs. Use Ctrl+C to stop."
        # Keep the container running for cron jobs
        while true; do
            sleep 3600  # Sleep for 1 hour, then check again
        done
    else
        log_warn "No cron jobs found. Container will exit."
        exit 0
    fi
elif [ $# -gt 0 ] && [ "$1" != "sh" ]; then
	log_info "Command mode enabled - executing provided command"
	log_verbose "Command: $*"

    # Execute the provided command as the configured user
	if [ "${CONTAINER_USER:-appuser}" = "root" ]; then
		exec "$@"
	else
		exec su-exec ${CONTAINER_USER:-appuser} "$@"
	fi
else
    log_info "Init mode enabled - executing scripts and exiting"
    
    # Execute scripts in init mode
    execute_init_scripts
    
    log_info "All init scripts completed successfully. Container exiting."
    exit 0
fi