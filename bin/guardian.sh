#!/bin/bash
#
# openclaw-guardian - Intelligent health monitoring and auto-recovery for OpenClaw
# 
# Monitors OpenClaw gateway health, detects failures, and restores service
# automatically with context-aware notifications.
#
# Usage: ./bin/guardian.sh [check|recover|status]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_DIR}/config/guardian.conf"
LOG_DIR="${LOG_DIR:-/tmp/openclaw-guardian}"
LOG_FILE="${LOG_DIR}/guardian.log"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Load tokens from tokens.txt (if exists)
TOKENS_FILE="${REPO_DIR}/config/tokens.txt"
if [[ -f "$TOKENS_FILE" ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Export the token
        export "$key=$value"
    done < "$TOKENS_FILE"
fi

# Defaults (can be overridden in config)
MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-3}"
RESTART_DELAY="${RESTART_DELAY:-10}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-120}"
NOTIFY_ON_SUCCESS="${NOTIFY_ON_SUCCESS:-false}"
WAKE_ON_ERROR="${WAKE_ON_ERROR:-true}"
AGENT_NAME="${AGENT_NAME:-Chip}"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Check if OpenClaw gateway is running
# Uses pgrep as primary check (reliable)
# openclaw gateway status returns 0 even when stopped, so we don't use it
check_gateway() {
    # Primary check: process exists
    if pgrep -f "openclaw-gateway" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Deep health check - tests connectivity (optional)
# Rate-limited to avoid Discord API throttling
check_connectivity() {
    # Skip if deep checks disabled
    if [[ "${DEEP_HEALTH_CHECK:-false}" != "true" ]]; then
        return 0
    fi
    
    local timeout="${CONNECTIVITY_TIMEOUT:-5}"
    local last_check_file="${LOG_DIR}/.last_connectivity_check"
    local min_interval="${CONNECTIVITY_CHECK_INTERVAL:-300}"  # Default: 5 minutes
    local now=$(date +%s)
    
    # Rate limiting - only check every N seconds
    if [[ -f "$last_check_file" ]]; then
        local last_check=$(cat "$last_check_file" 2>/dev/null || echo 0)
        local elapsed=$((now - last_check))
        if [[ $elapsed -lt $min_interval ]]; then
            # Too soon, skip check
            return 0
        fi
    fi
    
    # Update timestamp
    echo "$now" > "$last_check_file"
    
    log "INFO" "Running deep connectivity check"
    
    # Check 1: Local gateway port
    if command -v nc &> /dev/null; then
        if ! nc -z 127.0.0.1 18789 -w "$timeout" 2>/dev/null; then
            log "WARN" "Gateway port 18789 not responding (WebSocket probe failed)"
            return 1
        fi
    elif command -v curl &> /dev/null; then
        # Fallback using curl to localhost
        if ! curl -s --max-time "$timeout" http://127.0.0.1:18789/ > /dev/null 2>&1; then
            log "WARN" "Gateway port 18789 not responding"
            return 1
        fi
    fi
    
    # Check 2: Discord API (rate limited - only every 5 min default)
    if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
        # Only check Discord if we have a bot token
        if command -v curl &> /dev/null; then
            if ! curl -s --max-time "$timeout" \
                -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
                https://discord.com/api/v10/gateway > /dev/null 2>&1; then
                log "WARN" "Discord API unreachable (check network/bot token)"
                return 1
            fi
        fi
    fi
    
    log "INFO" "Deep connectivity check passed"
    return 0
}

# Get gateway status details
get_gateway_status() {
    local pid=$(pgrep -x "openclaw-gateway" 2>/dev/null || echo "not running")
    local uptime=""
    
    if [[ "$pid" != "not running" ]]; then
        uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || echo "unknown")
    fi
    
    echo "PID: $pid"
    echo "Uptime: $uptime"
}

# Attempt to restart the gateway
# Uses OpenClaw's built-in gateway management
restart_gateway() {
    local attempt=1
    
    log "INFO" "Attempting gateway restart (max $MAX_RESTART_ATTEMPTS attempts)"
    
    while [[ $attempt -le $MAX_RESTART_ATTEMPTS ]]; do
        log "INFO" "Restart attempt $attempt/$MAX_RESTART_ATTEMPTS"
        
        # Use OpenClaw's built-in gateway management
        if command -v openclaw &> /dev/null; then
            # First try restart (if running)
            openclaw gateway restart 2>&1 | tee -a "$LOG_FILE" || true
            
            # Wait for restart
            sleep "$RESTART_DELAY"
            
            # Check if it's back
            if check_gateway; then
                log "INFO" "Gateway restart successful on attempt $attempt"
                
                if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
                    notify "Gateway Recovered" "OpenClaw gateway restarted successfully after $attempt attempt(s)"
                fi
                
                return 0
            fi
            
            # If restart didn't work, try explicit start
            log "INFO" "Restart didn't bring gateway up, trying explicit start"
            openclaw gateway start 2>&1 | tee -a "$LOG_FILE" || true
        else
            log "ERROR" "openclaw command not found in PATH"
            notify "Gateway Recovery Failed" "openclaw command not found. Please check installation." "critical"
            return 1
        fi
        
        # Wait and check
        sleep "$RESTART_DELAY"
        
        if check_gateway; then
            log "INFO" "Gateway start successful on attempt $attempt"
            
            if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
                notify "Gateway Recovered" "OpenClaw gateway started successfully after $attempt attempt(s)"
            fi
            
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "Gateway restart failed after $MAX_RESTART_ATTEMPTS attempts"
    return 1
}

# Send notification to user
notify() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"
    
    # Try different notification methods
    if command -v notify-send &> /dev/null; then
        notify-send "$title" "$message" --urgency="$urgency" 2>/dev/null || true
    fi
    
    # Also log it
    log "NOTIFY" "$title: $message"
}

# Check for recent errors in Chip's session
check_recent_errors() {
    local session_file="${HOME}/.openclaw/agents/main/sessions/main.jsonl"
    local error_patterns="error|failed|tool failed|execution failed|gateway.*down"
    local check_window="${ERROR_CHECK_WINDOW:-10}"
    
    if [[ ! -f "$session_file" ]]; then
        return 1
    fi
    
    # Check last N lines for error patterns
    local recent_errors=$(tail -n "$check_window" "$session_file" 2>/dev/null | \
        grep -iE "$error_patterns" | \
        grep '"role":"assistant"' | \
        wc -l)
    
    if [[ "$recent_errors" -gt 0 ]]; then
        log "INFO" "Detected $recent_errors recent error(s) in agent session"
        return 0
    else
        return 1
    fi
}

# Wake up the agent with context
wake_agent() {
    local reason="$1"
    local context="${2:-}"
    
    if [[ "$WAKE_ON_ERROR" != "true" ]]; then
        log "INFO" "WAKE_ON_ERROR disabled, skipping agent wake-up"
        return 0
    fi
    
    log "INFO" "Waking $AGENT_NAME - Reason: $reason"
    
    # This will trigger a session reconnect
    # The message content helps Chip understand what happened
    local message="System Notice: $AGENT_NAME - $reason"
    
    if [[ -n "$context" ]]; then
        message="$message. Context: $context"
    fi
    
    # Use OpenClaw's messaging if available, otherwise log for manual action
    if command -v openclaw &> /dev/null; then
        # This would need to be configured with proper channel
        log "INFO" "Would send wake-up: $message"
        # openclaw message send --agent main "$message" 2>/dev/null || true
    else
        # Fallback: just notify the user
        notify "🤖 $AGENT_NAME Needs Attention" "$message" "critical"
    fi
}

# Main health check function
health_check() {
    log "INFO" "Starting health check"
    
    local status="healthy"
    local actions_taken=()
    
    # Check 1: Gateway process
    if ! check_gateway; then
        log "WARN" "Gateway not running"
        status="recovering"
        
        # Attempt auto-recovery
        if restart_gateway; then
            actions_taken+=("gateway_restart_success")
            # Give it a moment to stabilize
            sleep 5
        else
            actions_taken+=("gateway_restart_failed")
            wake_agent "Gateway restart failed after $MAX_RESTART_ATTEMPTS attempts" "Manual intervention required"
            notify "🚨 Gateway Down" "Auto-recovery failed. Manual restart required." "critical"
            return 1
        fi
    else
        log "INFO" "Gateway is healthy"
    fi
    
    # Check 2: Connectivity (deep check, only if process is running)
    if [[ "$status" == "healthy" ]] && ! check_connectivity; then
        log "WARN" "Gateway process running but connectivity issues detected"
        status="recovering"
        actions_taken+=("connectivity_issue")
        
        # Try restart to fix connectivity
        if restart_gateway; then
            actions_taken+=("restart_fixed_connectivity")
            sleep 5
        else
            actions_taken+=("restart_failed")
            wake_agent "Gateway connectivity failed and restart failed" "Network or service issue"
            return 1
        fi
    fi
    
    # Check 3: Recent errors in session (only if gateway is up)
    if [[ "$status" == "healthy" ]] && check_recent_errors; then
        log "WARN" "Recent errors detected in agent session"
        actions_taken+=("errors_detected")
        
        # Try gentle recovery first
        log "INFO" "Attempting gentle recovery (gateway cycle)"
        
        # Quick gateway cycle
        openclaw gateway restart 2>&1 | tee -a "$LOG_FILE" || true
        sleep "$RESTART_DELAY"
        
        if check_gateway; then
            wake_agent "Recovered from error state" "Gateway was cycled due to detected errors"
            actions_taken+=("gentle_recovery_success")
        else
            wake_agent "Error recovery failed" "Gateway cycle did not resolve issues"
            actions_taken+=("gentle_recovery_failed")
            return 1
        fi
    fi
    
    # Log summary
    log "INFO" "Health check complete. Status: $status, Actions: ${actions_taken[*]}"
    
    return 0
}

# Show current status
show_status() {
    echo "╔════════════════════════════════════════╗"
    echo "║     OpenClaw Guardian Status          ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    
    if check_gateway; then
        echo "✅ Gateway Status: RUNNING"
        get_gateway_status
    else
        echo "❌ Gateway Status: NOT RUNNING"
    fi
    
    echo ""
    echo "📊 Configuration:"
    echo "  Max restart attempts: $MAX_RESTART_ATTEMPTS"
    echo "  Restart delay: ${RESTART_DELAY}s"
    echo "  Health check interval: ${HEALTH_CHECK_INTERVAL}s"
    echo "  Wake on error: $WAKE_ON_ERROR"
    echo "  Notify on success: $NOTIFY_ON_SUCCESS"
    echo "  Deep health check: ${DEEP_HEALTH_CHECK:-false}"
    if [[ "${DEEP_HEALTH_CHECK:-false}" == "true" ]]; then
        echo "  Connectivity timeout: ${CONNECTIVITY_TIMEOUT:-5}s"
        echo "  Connectivity interval: ${CONNECTIVITY_CHECK_INTERVAL:-300}s"
    fi
    echo ""
    
    echo "📁 Log file: $LOG_FILE"
    
    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo "📝 Recent activity (last 5 entries):"
        tail -5 "$LOG_FILE" | sed 's/^/  /'
    fi
    
    # Show last connectivity check if deep checks enabled
    if [[ "${DEEP_HEALTH_CHECK:-false}" == "true" ]]; then
        local last_check_file="${LOG_DIR}/.last_connectivity_check"
        if [[ -f "$last_check_file" ]]; then
            local last_check=$(cat "$last_check_file" 2>/dev/null)
            local now=$(date +%s)
            local elapsed=$((now - last_check))
            echo ""
            echo "🔌 Last connectivity check: ${elapsed}s ago"
        fi
    fi
}

# Main command handler
case "${1:-check}" in
    check)
        health_check
        ;;
    status)
        show_status
        ;;
    recover)
        if ! check_gateway; then
            restart_gateway
        else
            log "INFO" "Gateway already running, no recovery needed"
        fi
        ;;
    *)
        echo "Usage: $0 [check|status|recover]"
        echo ""
        echo "Commands:"
        echo "  check   - Run health check and auto-recover if needed (default)"
        echo "  status  - Show current status and recent logs"
        echo "  recover - Force gateway restart"
        exit 1
        ;;
esac
