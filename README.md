# OpenClaw Guardian 🛡️

> Intelligent health monitoring and auto-recovery system for OpenClaw. Watches the gateway, detects failures, and restores service automatically with context-aware notifications.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Overview

OpenClaw Guardian keeps your OpenClaw deployment healthy by monitoring the gateway process, detecting failures, and automatically recovering from errors. When something goes wrong, it can intelligently decide whether to silently fix the issue or wake up your agent with full context.

### Why This Matters

If you've ever had your OpenClaw agent session freeze mid-conversation, you know the pain:
- Tools stop responding
- Commands fail silently
- You have to manually wake up the agent
- Context may be lost

**Guardian prevents this** by watching your gateway and taking action before you even notice there's a problem.

## Features

### 🔍 Smart Health Monitoring
- **Process monitoring**: Watches the `openclaw-gateway` process
- **Error pattern detection**: Scans recent agent session for error indicators
- **Multi-layer checks**: Gateway status + session health + tool responsiveness

### 🤖 Auto-Recovery
- **Automatic restart**: Attempts to restart the gateway when it fails
- **Configurable retries**: Set max attempts and delays
- **Gentle recovery**: For soft errors, tries a quick gateway cycle first
- **Escalation**: Knows when to wake the agent vs. handle silently

### 💬 Context-Aware Notifications
- **Smart wake-ups**: Only wakes your agent when human attention is needed
- **Rich context**: Agent wakes up knowing what went wrong
- **Desktop notifications**: Local alerts via `notify-send`
- **Discord integration**: Optional webhook notifications (coming soon)

### 🔧 Easy Deployment
- **One-command install**: `./install.sh`
- **systemd integration**: Services start on boot, auto-restart
- **Cron backup**: Optional cron-based monitoring
- **Minimal configuration**: Works out of the box, customize as needed

## Installation

### Prerequisites

- Linux with systemd
- OpenClaw installed (with working `openclaw gateway start`)
- Bash 4.0+
- `notify-send` (optional, for desktop notifications)

### Quick Install

```bash
# Clone the repository
cd ~/Documents/GitHub
git clone https://github.com/yourusername/openclaw-guardian.git
cd openclaw-guardian

# Create your configuration from the example
cp config/guardian.conf.example config/guardian.conf

# Edit the configuration (add your Discord bot token for deep checks)
nano config/guardian.conf

# Run the installer
./install.sh

# Follow the prompts to enable services
```

### Configuration Setup

**IMPORTANT:** The `config/guardian.conf` file contains sensitive information (Discord bot tokens) and is **not** included in the git repository for security reasons.

**To set up:**

1. **Copy the example config:**
   ```bash
   cp config/guardian.conf.example config/guardian.conf
   ```

2. **Edit the config and add your Discord bot token:**
   ```bash
   nano config/guardian.conf
   ```
   
   Find this line:
   ```bash
   DISCORD_BOT_TOKEN="<YOUR-DISCORD-BOT-TOKEN>"
   ```
   
   Replace with your actual token from the [Discord Developer Portal](https://discord.com/developers/applications)

3. **The `config/guardian.conf` file is gitignored** - your token will never be committed

**Note:** If you don't add a Discord token, deep health checks will still work for local WebSocket testing, but Discord API connectivity checks will be skipped.

### Manual Setup

If you prefer manual setup:

```bash
# 1. Ensure OpenClaw gateway is managed by OpenClaw itself
# (Not by systemd - OpenClaw has built-in gateway management)
openclaw gateway start

# 2. Copy guardian timer service
sudo cp systemd/openclaw-guardian.service /etc/systemd/system/
sudo cp systemd/openclaw-guardian.timer /etc/systemd/system/

# 3. Customize for your user
sudo sed -i 's/%I/your-username/g' /etc/systemd/system/openclaw-guardian.service

# 4. Reload and enable
sudo systemctl daemon-reload
sudo systemctl enable openclaw-guardian.timer

# 5. Start the timer
sudo systemctl start openclaw-guardian.timer
```

## Usage

### Manual Health Check

```bash
# Check current status
./bin/guardian.sh status

# Run health check (auto-recovers if needed)
./bin/guardian.sh check

# Force gateway restart
./bin/guardian.sh recover
```

### Automatic Monitoring

Once installed, Guardian runs automatically:

- **Every 2 minutes**: Health check via systemd timer
- **On boot**: Gateway starts automatically
- **On crash**: Gateway restarts automatically (up to 3 attempts)

### View Logs

```bash
# Guardian logs
tail -f /tmp/openclaw-guardian/guardian.log

# Systemd journal
sudo journalctl -u openclaw-guardian -f

# Gateway logs
sudo journalctl -u openclaw-gateway@your-username -f
```

## How It Works

### The Decision Matrix

| Scenario | Action | Cost |
|----------|--------|------|
| Gateway down | Auto-restart | $0 |
| Restart succeeds | Silent success | $0 |
| Restart fails | Notify user, wake agent | $$$ |
| Recent errors detected | Gentle recovery (restart) | $0-$ |
| Gentle recovery succeeds | Wake agent with context | $$$ |
| Gateway healthy | Do nothing | $0 |

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    systemd Timer                            │
│                (Every 2 minutes)                            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│              OpenClaw Guardian Check                        │
│  1. Is gateway running? (pgrep)                             │
│  2. Any recent errors in session? (grep logs)               │
└──────────┬──────────────────────────────┬───────────────────┘
           │                              │
     ┌─────▼─────┐                  ┌─────▼─────┐
     │  Healthy  │                  │  Issues   │
     │  Do nothing                  │  Detected │
     └───────────┘                  └─────┬─────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
              ┌─────▼─────┐         ┌─────▼─────┐         ┌─────▼─────┐
              │ Gateway   │         │ Soft Error│         │ Hard Error│
              │ Down      │         │ (session) │         │ (restart  │
              │           │         │           │         │  failed)  │
              └─────┬─────┘         └─────┬─────┘         └─────┬─────┘
                    │                     │                     │
                    ▼                     ▼                     ▼
           ┌──────────────┐       ┌──────────────┐     ┌──────────────┐
           │ Auto-restart │       │ Gentle cycle │     │ Wake agent   │
           │ (silent)     │       │ + context    │     │ + notify user│
           └──────────────┘       └──────────────┘     └──────────────┘
```

### Error Detection

Guardian looks for these patterns in recent agent session logs:

- `"error"` - General errors
- `"failed"` - Operation failures  
- `"tool failed"` - Tool execution failures
- `"execution failed"` - Command failures
- `"gateway.*down"` - Gateway issues

You can customize these patterns in the config.

### Deep Health Checks (Recommended for Orchestrators)

**For orchestration agents, deep health checks are STRONGLY RECOMMENDED.**

They catch Discord/WebSocket errors like:
- `"Expected ',' or '}' after property value in JSON" ` — WebSocket corruption
- `"Discord connection failed"` — API connectivity issues
- `Gateway running but Discord unresponsive` — Partial failures

| Check | What It Tests | Rate Limit |
|-------|--------------|------------|
| Process | `pgrep openclaw-gateway` | Every 2 min |
| WebSocket | `nc -z 127.0.0.1 18789` | Every 5 min (configurable) |
| Discord API | `curl` to Discord endpoint | Every 5 min (configurable) |

**Why enable for orchestrators?**
- Discord is your message bus — if it's down, workers can't communicate
- JSON parsing errors can leave sessions in a broken state
- Deep checks detect issues before they cascade

**Configuration (set these in your guardian.conf):**
```bash
# Enable deep checks (default: true for orchestrators)
DEEP_HEALTH_CHECK=true
CONNECTIVITY_TIMEOUT=5
CONNECTIVITY_CHECK_INTERVAL=300  # 5 minutes

# Optional but recommended: Add your Discord bot token
# This enables actual Discord API connectivity testing
DISCORD_BOT_TOKEN="your-bot-token-here"
```

## Configuration

Create `config/guardian.conf`:

```bash
# Gateway settings
MAX_RESTART_ATTEMPTS=3        # How many times to retry
RESTART_DELAY=10              # Seconds between attempts
HEALTH_CHECK_INTERVAL=120     # Seconds between checks

# Notification settings
NOTIFY_ON_SUCCESS=false       # Desktop notify even on success
WAKE_ON_ERROR=true           # Wake agent when errors detected
AGENT_NAME="Chip"            # Name for notifications

# Deep health checks (optional - see README for details)
DEEP_HEALTH_CHECK=false      # Enable connectivity testing
CONNECTIVITY_TIMEOUT=5       # Seconds to wait for connections
CONNECTIVITY_CHECK_INTERVAL=300  # Min seconds between checks (5 min)
# DISCORD_BOT_TOKEN=""        # Optional: enables Discord API check

# Advanced
ERROR_CHECK_WINDOW=10         # Lines of session to check
# LOG_DIR=/var/log/guardian   # Custom log location
```

See `config/guardian.conf.example` for all options.

## Architecture

### Components

| File | Purpose |
|------|---------|
| `bin/guardian.sh` | Main health check and recovery logic |
| `systemd/openclaw-gateway@.service` | systemd service for gateway |
| `systemd/openclaw-guardian.service` | One-shot health check runner |
| `systemd/openclaw-guardian.timer` | Triggers health check every 2 min |
| `config/guardian.conf` | User configuration |

### File Locations

```
~/Documents/GitHub/openclaw-guardian/
├── bin/
│   └── guardian.sh              # Main script
├── systemd/
│   ├── openclaw-gateway@.service     # Gateway service
│   ├── openclaw-guardian.service     # Health check service
│   └── openclaw-guardian.timer       # Timer (every 2 min)
├── config/
│   └── guardian.conf.example   # Config template
├── install.sh                  # Installation script
└── README.md                   # This file

Runtime:
/tmp/openclaw-guardian/
├── guardian.log               # Health check logs
└── cron.log                   # Cron job logs (if enabled)
```

## Troubleshooting

### "Gateway not found in PATH"

Make sure `openclaw` is in your PATH:
```bash
which openclaw
# If not found, add to ~/.bashrc:
export PATH="$PATH:/usr/local/bin"
```

### Services not starting

Check systemd status:
```bash
sudo systemctl status openclaw-gateway@$USER
sudo systemctl status openclaw-guardian
```

Common issues:
- Wrong user in service file
- Missing execute permissions
- Path to openclaw incorrect

### Too many notifications

Edit `config/guardian.conf`:
```bash
NOTIFY_ON_SUCCESS=false  # Only notify on failures
WAKE_ON_ERROR=false      # Don't wake agent (manual only)
```

### Agent not being woken

Check if session file exists:
```bash
ls -la ~/.openclaw/agents/main/sessions/main.jsonl
```

If empty or missing, Guardian can't detect errors in session.

## Contributing

Contributions welcome! Areas for improvement:

- [ ] Discord webhook notifications
- [ ] Slack/Teams integrations
- [ ] Web dashboard for status
- [ ] Metrics export (Prometheus)
- [ ] Email notifications
- [ ] Multi-agent support

## Credits

Created by Derrick with his OpenClaw buddy Chip.

Inspired by the challenges of keeping AI agent sessions healthy.

## License

MIT License - See [LICENSE](LICENSE) file for details.

---

**Pro Tip:** Run `./bin/guardian.sh status` anytime to see current health and recent activity!
