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
# MpVFX uninstaller, copied into the install folder; Settings > Apps > MpVFX > Uninstall runs it.
# Removes the program folder, the Start menu shortcut and the uninstall entry. Projects and settings stay.
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$dest = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dest 'MpVFX.exe'

Get-Process MpVFX -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
Start-Sleep -Milliseconds 300
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'MpVFX.lnk') -ErrorAction SilentlyContinue
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MpVFX' -Recurse -ErrorAction SilentlyContinue
Set-Location $env:TEMP
Remove-Item $dest -Recurse -Force
if (-not $Quiet) {
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show('MpVFX was removed. Your projects were not touched.', 'MpVFX') | Out-Null
}
