#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if grep -qF '$match = [regex]::Match($content, "(?m)^\\s*\\[")' "$WINDOWS_INSTALLER"; then
    fail "broken double-quoted PowerShell regex is still present"
fi

if ! grep -qF "\$match = [regex]::Match(\$content, '(?m)^\\s*\\[')" "$WINDOWS_INSTALLER"; then
    fail "fixed PowerShell-safe regex is missing"
fi

if command -v pwsh >/dev/null 2>&1; then
    ps_script="$(mktemp)"
    trap 'rm -f "$ps_script"' EXIT
    cat > "$ps_script" <<'EOF'
$content = "notify = [""powershell""]`n[profiles]"
$match = [regex]::Match($content, '(?m)^\s*\[')
if (-not $match.Success) { exit 1 }
if ($match.Index -lt 0) { exit 1 }
EOF
    if ! pwsh -NoProfile -File "$ps_script"; then
        fail "PowerShell-safe regex failed under pwsh"
    fi
fi

pass "Windows status regex uses a PowerShell-safe pattern"
