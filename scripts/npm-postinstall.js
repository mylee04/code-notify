#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

if (process.env.CODE_NOTIFY_SKIP_POSTINSTALL === '1') {
  process.exit(0);
}

const isGlobalInstall =
  process.env.npm_config_global === 'true' ||
  process.env.npm_config_location === 'global';

if (!isGlobalInstall) {
  process.exit(0);
}

if (process.platform !== 'win32') {
  const repairCommand = path.resolve(__dirname, '..', 'bin', 'npm-code-notify.js');
  const result = spawnSync(process.execPath, [repairCommand, 'repair-hooks', '--quiet'], {
    stdio: 'inherit',
    env: process.env
  });

  if (result.error || result.status !== 0) {
    console.warn('[code-notify] Legacy Claude hook repair did not complete during npm install.');
  }

  process.exit(0);
}

const installer = path.resolve(__dirname, 'install-windows.ps1');
const args = [
  '-ExecutionPolicy',
  'Bypass',
  '-NoProfile',
  '-File',
  installer,
  '-Silent',
  '-Force',
  '-SkipShellSetup'
];
const candidates = ['powershell.exe', 'powershell', 'pwsh.exe', 'pwsh'];

for (const candidate of candidates) {
  const result = spawnSync(candidate, args, {
    stdio: 'inherit',
    env: process.env
  });

  if (result.error && result.error.code === 'ENOENT') {
    continue;
  }

  if (result.error || result.status !== 0) {
    console.warn('[code-notify] Windows bootstrap did not complete during npm install.');
  }

  process.exit(0);
}

console.warn('[code-notify] PowerShell was not found during npm postinstall; first run will retry bootstrap.');
process.exit(0);
