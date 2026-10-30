# VS Code Agents Window Launcher

A PowerShell-based launcher for Visual Studio Code on Windows that allows the **Agents Window** to appear as a separate application on the Windows taskbar.

## Features
- Launches VS Code's dedicated Agents Window directly using `--agents`.
- Assigns a custom, window-level `AppUserModelID` to separate it from regular VS Code windows in the taskbar.
- Uses the official VS Code Agents icon (`sessions.ico`).
- Works with the existing VS Code installation, user profile, extensions, and settings.
- Supports launching from a cold start or while regular VS Code windows are already running.

This is an unofficial Windows taskbar integration workaround. It does not require a separate VS Code installation or user profile.

## Setup

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.exe.agents.ps1" -InstallShortcut
```

## Optional Steps before Setup (For VS Code 1.21 or older)
```powershell
$install = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
$bin = Join-Path $install 'bin'

New-Item -ItemType Directory -Path $bin -Force
```
