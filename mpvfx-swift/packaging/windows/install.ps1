#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
# MpVFX installer step, run by MpVFX-Setup.exe from its extraction folder (install.cmd starts it).
# Per-user install: %LOCALAPPDATA%\Programs\MpVFX, a Start menu shortcut and an entry in Settings > Apps
# (HKCU uninstall key). No administrator rights. -Quiet: no app launch at the end (CI and silent installs).
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = '@VERSION@'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\MpVFX'
$exe = Join-Path $dest 'MpVFX.exe'

# An older copy may be running from the install folder: close it so its files can be replaced.
Get-Process MpVFX -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
Start-Sleep -Milliseconds 300
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force $dest | Out-Null
Expand-Archive (Join-Path $here 'payload.zip') $dest -Force
Copy-Item (Join-Path $here 'uninstall.ps1') $dest

$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'MpVFX.lnk'))
$link.TargetPath = $exe
$link.WorkingDirectory = $dest
$link.IconLocation = (Join-Path $dest 'MpVFX.ico') + ',0'
$link.Description = 'MpVFX video editor'
$link.Save()

$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MpVFX'
$uninstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dest\uninstall.ps1`""
New-Item $key -Force | Out-Null
$sizeKB = [int]((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
$values = @{
  DisplayName = 'MpVFX'; DisplayVersion = $version; Publisher = 'OneTake'; InstallLocation = $dest
  DisplayIcon = (Join-Path $dest 'MpVFX.ico'); UninstallString = $uninstall; QuietUninstallString = "$uninstall -Quiet"
}
foreach ($name in $values.Keys) { Set-ItemProperty $key $name $values[$name] }
foreach ($name in 'NoModify', 'NoRepair') { New-ItemProperty $key $name -Value 1 -PropertyType DWord -Force | Out-Null }
New-ItemProperty $key 'EstimatedSize' -Value $sizeKB -PropertyType DWord -Force | Out-Null

if (-not $Quiet) { Start-Process $exe -WorkingDirectory $dest }
