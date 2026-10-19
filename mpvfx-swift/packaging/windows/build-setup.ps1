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
# Build MpVFX-Setup.exe from the portable app folder, with IExpress (part of Windows; no third-party tool).
# Run from mpvfx-swift\ in PowerShell 7 after the portable folder is assembled (CI: the "Package" step):
#   pwsh packaging/windows/build-setup.ps1 -AppDir <portable-folder> -Dist <dist-dir>
# Writes <dist-dir>\MpVFX-<version>-windows-x64-setup.exe and prints its path last.
# Silent install (CI): MpVFX-Setup.exe /Q:A   (runs install.cmd /quiet)
param(
  [Parameter(Mandatory)][string]$AppDir,
  [Parameter(Mandatory)][string]$Dist
)
$ErrorActionPreference = 'Stop'
$version = (Get-Content (Join-Path $PSScriptRoot '..\VERSION')).Trim()
New-Item -ItemType Directory -Force $Dist | Out-Null
$Dist = (Resolve-Path $Dist).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("mpvfx-setup-" + [guid]::NewGuid().ToString('N'))
$app = Join-Path $work 'app'; $src = Join-Path $work 'src'
New-Item -ItemType Directory -Force $app, $src | Out-Null

Copy-Item (Join-Path $AppDir '*') $app -Recurse
Copy-Item (Join-Path $PSScriptRoot '..\icon\mpvfx.ico') (Join-Path $app 'MpVFX.ico')
Compress-Archive -Path (Join-Path $app '*') -DestinationPath (Join-Path $src 'payload.zip') -CompressionLevel Optimal
(Get-Content (Join-Path $PSScriptRoot 'install.ps1') -Raw).Replace('@VERSION@', $version) |
  Set-Content (Join-Path $src 'install.ps1') -NoNewline
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1'), (Join-Path $PSScriptRoot 'install.cmd') $src

$target = Join-Path $Dist "MpVFX-$version-windows-x64-setup.exe"
Remove-Item $target -ErrorAction SilentlyContinue
$files = 'install.cmd', 'install.ps1', 'payload.zip', 'uninstall.ps1'
$strings = ($files | ForEach-Object -Begin { $i = 0 } -Process { "FILE$i=`"$_`""; $i++ }) -join "`r`n"
$entries = ($files | ForEach-Object -Begin { $i = 0 } -Process { "%FILE$i%="; $i++ }) -join "`r`n"
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=Install MpVFX $version for this Windows account?
DisplayLicense=
FinishMessage=MpVFX is installed. Find it in the Start menu.
TargetName=$target
FriendlyName=MpVFX $version Setup
AppLaunched=cmd /c install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=cmd /c install.cmd /quiet
UserQuietInstCmd=cmd /c install.cmd /quiet
$strings
[SourceFiles]
SourceFiles0=$src\
[SourceFiles0]
$entries
"@
$sedPath = Join-Path $work 'mpvfx.sed'
Set-Content $sedPath $sed -Encoding ascii
$p = Start-Process (Join-Path $env:WINDIR 'System32\iexpress.exe') -ArgumentList '/N', '/Q', $sedPath -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0 -or -not (Test-Path $target)) { throw "IExpress failed (exit $($p.ExitCode))" }
Remove-Item $work -Recurse -Force
Get-Item $target | Format-Table Name, Length | Out-Host
$target
