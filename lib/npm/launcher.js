#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const windowsShellCandidates = ['powershell.exe', 'powershell', 'pwsh.exe', 'pwsh'];

function exitWithSpawnResult(result, fallbackMessage) {
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      console.error(fallbackMessage);
    } else {
      console.error(result.error.message);
    }
    process.exit(1);
  }

  if (typeof result.status === 'number') {
    process.exit(result.status);
  }

  process.exit(1);
}

function spawnWithCandidates(candidates, args, options, missingMessage) {
  let lastResult = null;

  for (const candidate of candidates) {
    const result = spawnSync(candidate, args, options);
    if (result.error && result.error.code === 'ENOENT') {
      lastResult = result;
      continue;
    }
    return result;
  }

  return lastResult || {
    error: new Error(missingMessage)
  };
}

function ensureFile(filePath, message) {
  if (!fs.existsSync(filePath)) {
    console.error(message);
    process.exit(1);
  }
}

function runUnixCli(commandName, args) {
  const shellScript = path.join(repoRoot, 'bin', 'code-notify');
  ensureFile(shellScript, `code-notify runtime not found at ${shellScript}`);

  const result = spawnSync(
    'bash',
    [shellScript, ...args],
    {
      stdio: 'inherit',
      env: {
        ...process.env,
        CODE_NOTIFY_COMMAND_NAME: commandName,
        CODE_NOTIFY_INSTALL_METHOD: 'npm'
      }
    }
  );

  exitWithSpawnResult(result, 'bash is required to run code-notify.');
}

function bootstrapWindowsRuntime() {
  const installer = path.join(repoRoot, 'scripts', 'install-windows.ps1');
  ensureFile(installer, `Windows installer not found at ${installer}`);

  const result = spawnWithCandidates(
    windowsShellCandidates,
    [
      '-ExecutionPolicy',
      'Bypass',
      '-NoProfile',
      '-File',
      installer,
      '-Silent',
      '-Force',
      '-SkipShellSetup'
    ],
    {
      stdio: 'inherit',
      env: process.env
    },
    'PowerShell is required to bootstrap code-notify on Windows.'
  );

  if (result.error || result.status !== 0) {
    exitWithSpawnResult(result, 'PowerShell is required to bootstrap code-notify on Windows.');
  }
}

function runWindowsCli(commandName, args) {
  const runtimeScript = path.join(os.homedir(), '.code-notify', 'bin', `${commandName}.ps1`);

  if (!fs.existsSync(runtimeScript)) {
    bootstrapWindowsRuntime();
  }

  ensureFile(runtimeScript, `code-notify runtime not found at ${runtimeScript}`);

  const result = spawnWithCandidates(
    windowsShellCandidates,
    [
      '-ExecutionPolicy',
      'Bypass',
      '-NoProfile',
      '-File',
      runtimeScript,
      ...args
    ],
    {
      stdio: 'inherit',
      env: {
        ...process.env,
        CODE_NOTIFY_INSTALL_METHOD: 'npm'
      }
    },
    'PowerShell is required to run code-notify on Windows.'
  );

  exitWithSpawnResult(result, 'PowerShell is required to run code-notify on Windows.');
}

function runCli(commandName, args) {
  if (process.platform === 'win32') {
    runWindowsCli(commandName, args);
    return;
  }

  runUnixCli(commandName, args);
}

module.exports = {
  runCli
};
