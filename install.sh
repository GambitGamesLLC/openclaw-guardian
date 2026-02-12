#!/bin/bash
#
# OpenClaw Guardian - Installation Script
#
# Usage: ./install.sh [user]
# Default user: current user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${1:-$USER}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root (we don't want that)
if [[ $EUID -eq 0 ]]; then
   log_error "Do not run this script as root. It will use sudo when needed."
   exit 1
fi

log_info "Installing OpenClaw Guardian for user: $TARGET_USER"
log_info "Repository location: $SCRIPT_DIR"

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v systemctl &> /dev/null; then
    log_error "systemctl not found. This script requires systemd."
    exit 1
fi

if ! command -v openclaw &> /dev/null; then
    log_warn "openclaw command not found in PATH. Make sure OpenClaw is installed."
    log_warn "You may need to manually update the systemd service files."
fi

# Create log directory
log_info "Creating log directory..."
mkdir -p /tmp/openclaw-guardian
mkdir -p "$HOME/.local/share/openclaw-guardian"

# Install systemd service files (requires sudo)
log_info "Installing systemd service files..."

# Copy guardian service files to systemd
# Note: We don't install openclaw-gateway@.service because OpenClaw
# manages its own gateway via 'openclaw gateway start' command
sudo cp "$SCRIPT_DIR/systemd/openclaw-guardian.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/openclaw-guardian.timer" /etc/systemd/system/

# Replace user placeholder in service files
sudo sed -i "s/%I/$TARGET_USER/g" /etc/systemd/system/openclaw-guardian.service

# Update paths in service files to match actual install location
sudo sed -i "s|/home/$TARGET_USER/Documents/GitHub/openclaw-guardian|$SCRIPT_DIR|g" /etc/systemd/system/openclaw-guardian.service

log_info "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Create config file from example if it doesn't exist
CONFIG_FILE="$SCRIPT_DIR/config/guardian.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_info "Creating configuration file from example..."
    cp "$SCRIPT_DIR/config/guardian.conf.example" "$CONFIG_FILE"
    log_info "Please edit $CONFIG_FILE to customize settings"
fi

# Ask about enabling services
log_info ""
log_info "Systemd services installed. Choose setup option:"
echo ""
echo "1) Enable guardian health monitoring only (recommended)"
echo "2) Manual setup - don't enable anything"
echo ""
read -p "Enter choice [1-2]: " choice

case $choice in
    1)
        log_info "Enabling OpenClaw Guardian monitoring..."
        log_info "Note: OpenClaw gateway should be started with 'openclaw gateway start'"
        sudo systemctl enable openclaw-guardian.timer
        sudo systemctl start openclaw-guardian.timer
        log_info "Guardian timer enabled and started"
        log_info ""
        log_info "Make sure OpenClaw gateway is running:"
        echo "  openclaw gateway start"
        ;;
    2)
        log_info "Skipping service enablement"
        log_info "You can manually enable services later with:"
        echo "  sudo systemctl enable openclaw-guardian.timer"
        ;;
    *)
        log_warn "Invalid choice, skipping service enablement"
        ;;
esac

# Create cron job as alternative/backup
log_info ""
read -p "Also install cron job for health checks? [y/N]: " install_cron

if [[ "$install_cron" =~ ^[Yy]$ ]]; then
    CRON_JOB="*/2 * * * * $SCRIPT_DIR/bin/guardian.sh check >> /tmp/openclaw-guardian/cron.log 2>&1"
    
    # Check if already installed
    if crontab -l 2>/dev/null | grep -q "openclaw-guardian"; then
        log_warn "Cron job already exists, skipping"
    else
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        log_info "Cron job installed (runs every 2 minutes)"
    fi
else
    log_info "Skipping cron job installation"
fi

# Final instructions
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               Installation Complete!                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_info "OpenClaw Guardian is installed at: $SCRIPT_DIR"
echo ""
echo "Quick Commands:"
echo "  Check status:    $SCRIPT_DIR/bin/guardian.sh status"
echo "  Manual check:    $SCRIPT_DIR/bin/guardian.sh check"
echo "  Force recovery:  $SCRIPT_DIR/bin/guardian.sh recover"
echo "  Gateway status:  openclaw gateway status"
echo "  Start gateway:   openclaw gateway start"
echo ""
echo "Systemd Commands:"
echo "  View guardian:   sudo systemctl status openclaw-guardian"
echo "  View timer:      sudo systemctl list-timers openclaw-guardian"
echo ""
echo "Logs:"
echo "  Guardian logs:   /tmp/openclaw-guardian/guardian.log"
echo "  Journal logs:    sudo journalctl -u openclaw-guardian -f"
echo ""
echo "Configuration:"
echo "  Edit settings:   $SCRIPT_DIR/config/guardian.conf"
echo ""
echo "Next Steps:"
echo "  1. Ensure OpenClaw gateway is running: openclaw gateway start"
echo "  2. Review and customize $SCRIPT_DIR/config/guardian.conf"
echo "  3. Test with: $SCRIPT_DIR/bin/guardian.sh check"
echo "  4. Check logs: sudo journalctl -u openclaw-guardian -f"
echo ""
