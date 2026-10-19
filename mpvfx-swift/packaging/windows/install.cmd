@echo off
:: ===----------------------------------------------------------------------===
::
:: This source file is part of MpVFX.
::
:: Copyright (c) 2026 Arshiya Rahgozar.
::
:: Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
:: http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
:: or http://opensource.org/licenses/MIT), at your option.
::
:: SPDX-License-Identifier: MIT OR Apache-2.0
::
:: ===----------------------------------------------------------------------===
rem Started by MpVFX-Setup.exe in its extraction folder; "/quiet" installs without launching the app.
set QUIET=
if /I "%~1"=="/quiet" set QUIET=-Quiet
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %QUIET%
exit /b %ERRORLEVEL%
