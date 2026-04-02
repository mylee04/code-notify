#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if ! grep -qF '$NotificationStateDir = "$NotificationsDir\state"' "$WINDOWS_INSTALLER"; then
    fail "installer should create a dedicated notifications state directory"
fi

if ! grep -qF '$NotificationStateDir = "$ClaudeHome\notifications\state"' "$WINDOWS_INSTALLER"; then
    fail "generated Windows notifier should store rate-limit files under notifications\\state"
fi

if ! grep -qF 'function Get-LegacyRateLimitPath' "$WINDOWS_INSTALLER"; then
    fail "legacy rate-limit fallback helper is missing from the Windows notifier"
fi

if ! grep -qF 'Join-Path "$ClaudeHome\notifications" $safeKey' "$WINDOWS_INSTALLER"; then
    fail "Windows legacy rate-limit fallback path is missing"
fi

if command -v pwsh >/dev/null 2>&1; then
    ps_script="$(mktemp)"
    trap 'rm -f "$ps_script"' EXIT
    cat > "$ps_script" <<'EOF'
$ClaudeHome = "/tmp/tester/.claude"
$NotificationStateDir = "$ClaudeHome\notifications\state"

function Get-RateLimitPath {
    param([string]$Key)
    $safeKey = ($Key -replace '[^A-Za-z0-9._-]', '_')
    return Join-Path $NotificationStateDir $safeKey
}

function Get-LegacyRateLimitPath {
    param([string]$Key)
    $safeKey = ($Key -replace '[^A-Za-z0-9._-]', '_')
    return Join-Path "$ClaudeHome\notifications" $safeKey
}

$expectedState = "/tmp/tester/.claude/notifications/state/last_notification_claude_demo_idle_prompt"
$expectedLegacy = "/tmp/tester/.claude/notifications/last_notification_claude_demo_idle_prompt"

if ((Get-RateLimitPath "last_notification_claude_demo_idle_prompt") -ne $expectedState) { exit 1 }
if ((Get-LegacyRateLimitPath "last_notification_claude_demo_idle_prompt") -ne $expectedLegacy) { exit 1 }
EOF
    if ! pwsh -NoProfile -File "$ps_script"; then
        fail "Windows rate-limit paths should resolve to state and legacy locations"
    fi
fi

pass "Windows notifier stores rate-limit state under notifications\\state with legacy fallback"
