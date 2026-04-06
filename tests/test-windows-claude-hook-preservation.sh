#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if ! command -v pwsh >/dev/null 2>&1; then
    pass "pwsh not installed; skipping Windows Claude hook preservation test"
    exit 0
fi

ps_script="$(mktemp)"
trap 'rm -f "$ps_script"' EXIT

cat > "$ps_script" <<'EOF'
param([string]$InstallerPath)

$ErrorActionPreference = "Stop"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("code-notify-win-" + [guid]::NewGuid().ToString())

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:USERPROFILE = $testRoot

    $content = Get-Content -Raw $InstallerPath
    if ($content -notmatch "(?ms)\$mainScript = @'\r?\n(?<module>.*?)\r?\n'@") {
        throw "could not extract Code-Notify PowerShell module from installer"
    }
    $moduleScript = $Matches['module']
    $moduleScript = $moduleScript -replace '(?ms)\r?\nExport-ModuleMember -Function @\(.*?\)\s*$', ''
    Invoke-Expression $moduleScript

    $script:ClaudeHome = Join-Path $env:USERPROFILE ".claude"
    $script:DefaultSettingsFile = Join-Path $script:ClaudeHome "settings.json"
    $script:AlternateSettingsFile = Join-Path (Join-Path $env:USERPROFILE ".config\.claude") "settings.json"
    $script:SettingsFile = $script:DefaultSettingsFile
    $script:NotificationsDir = Join-Path $script:ClaudeHome "notifications"
    $script:VoiceFile = Join-Path $script:NotificationsDir "voice-enabled"
    $script:SoundEnabledFile = Join-Path $script:NotificationsDir "sound-enabled"
    $script:SoundCustomFile = Join-Path $script:NotificationsDir "sound-custom"
    $script:LogsDir = Join-Path $script:ClaudeHome "logs"

    function Send-Notification { param([string]$Title, [string]$Message, [string]$Type) }
    function Write-ClaudeProjectTrustWarning { param([string]$ProjectRoot) }

    New-Item -ItemType Directory -Path $script:ClaudeHome, $script:NotificationsDir, $script:LogsDir -Force | Out-Null

    @'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "custom_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom notification"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre"
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
'@ | Set-Content $script:SettingsFile -Encoding UTF8

    if (Test-NotificationsEnabled -Tool "claude") {
        throw "custom Claude hooks were incorrectly treated as current code-notify hooks"
    }

    Enable-Notifications -Tool "claude"

    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    $notifyCommand = Get-ClaudeNotifyCommand -NotifyScript (Get-NotifyScript)
    $stopCommand = Get-ClaudeStopCommand -NotifyScript (Get-NotifyScript)

    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
        throw "PreToolUse hook was removed during enable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "custom_prompt" -Command "echo custom notification")) {
        throw "custom Notification hook was removed during enable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "idle_prompt" -Command $notifyCommand)) {
        throw "current Claude Notification hook was not added"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $stopCommand)) {
        throw "current Claude Stop hook was not added"
    }

    Disable-Notifications -Tool "claude"

    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
        throw "PreToolUse hook was removed during disable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "custom_prompt" -Command "echo custom notification")) {
        throw "custom Notification hook was removed during disable"
    }
    if ($settings.hooks.PSObject.Properties['Stop']) {
        throw "managed Stop hook should be removed during disable"
    }
    if (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "idle_prompt" -Command $notifyCommand) {
        throw "managed Notification hook should be removed during disable"
    }

    Remove-Item $script:SettingsFile -Force -ErrorAction SilentlyContinue

    Enable-Notifications -Tool "claude"
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings.hooks) {
        throw "managed hooks were not created for the clean settings case"
    }

    Disable-Notifications -Tool "claude"
    if (Test-Path $script:SettingsFile) {
        $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($settings.hooks) {
            throw "hooks should be removed entirely when only managed Claude hooks existed"
        }
    }
}
finally {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
EOF

if ! pwsh -NoProfile -File "$ps_script" "$WINDOWS_INSTALLER"; then
    fail "Windows Claude hook preservation behavior regressed"
fi

pass "Windows Claude hook detection and preservation stay aligned"
