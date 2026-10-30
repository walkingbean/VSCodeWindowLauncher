# VS Code Agents Window Launcher

A PowerShell-based launcher for Visual Studio Code on Windows that allows the **Agents Window** to appear as a separate application on the Windows taskbar.

## Features

- Launches the dedicated Agents Window directly using the `--agents` command-line argument.
- Assigns a custom, window-level `AppUserModelID` to separate it from regular VS Code windows in the taskbar.
- Uses the official VS Code Agents icon (`sessions.ico`).
- Works with the existing VS Code installation, user profile, extensions, settings, and authentication.
- Supports cold starts and launching while regular VS Code windows are already running.
- Creates a dedicated Start Menu shortcut that can be pinned to the Windows taskbar.

## Prerequisites

- **Operating System:** 64-bit Windows 10 or Windows 11.
- **Visual Studio Code:** An installed desktop version that supports the Agents Window and the `--agents` command-line argument.
- **PowerShell:** 64-bit Windows PowerShell 5.1 or later.
- **Permissions:** Standard user permissions are sufficient. Administrator privileges are not required.
- **Dependencies:** No additional third-party libraries or software are required. The script uses built-in Windows APIs, .NET, and COM interfaces.

### Official Agents Icon

The script automatically searches the VS Code installation directory for the official `sessions.ico` file.
It supports both standard and versioned resource directory layouts.
If the icon cannot be found, the script falls back to the standard VS Code icon.

## Installation and Setup

### 1. Save the Script

Save `code.exe.agents.ps1` in a suitable location. For example:
```text
%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.exe.agents.ps1
```
The script can also be stored in another location, provided it can locate the VS Code installation.

### 2. Optional Step before Setup (For VS Code 1.21 or older)
```powershell
$install = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
$bin = Join-Path $install 'bin'

New-Item -ItemType Directory -Path $bin -Force
```

### 3. Create the Start Menu Shortcut

Open 64-bit Windows PowerShell and run:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\Code-Agents.ps1" -InstallShortcut
```
Replace the example path with the actual location of the script.

The `-InstallShortcut` parameter:

- Creates or updates the `VS Code Agents` shortcut in the Windows Start Menu.
- Assigns the custom AppUserModelID `Local.VSCode.Agents`.
- Sets the official Agents Window icon when available.
- Configures the shortcut to launch the PowerShell script.

### 4. Pin to the Taskbar

1. Open the Windows Start Menu.
2. Find `VS Code Agents`.
3. Right-click it and select **Pin to taskbar**.

You should now have separate taskbar entries for:

- **Visual Studio Code:** Regular code editor windows.
- **VS Code Agents:** The dedicated Agents Window.

## Run Usage

### Launching Agents Window

Click the pinned `VS Code Agents` icon on the Windows taskbar.

The launcher automatically:

1. Detects existing VS Code windows.
2. Starts VS Code with the `--agents` argument.
3. Waits for the new Agents Window to appear.
4. Identifies the newly created window handle (HWND).
5. Assigns the custom window-level AppUserModelID.
6. Activates the Agents Window.

No manual commands or additional steps are required during normal use.

### Supported Launch Scenarios

| Scenario | Supported |
|---|---|
| Windows has just booted and VS Code has not been started | Yes |
| All VS Code processes have been closed | Yes |
| Regular VS Code editor is already running | Yes |
| Regular VS Code editor remains open while Agents Window is launched | Yes |
| An Agents Window is already open before launching through the shortcut | Not recommended |

The launcher supports both cold starts and launches through an existing VS Code instance.

## Runtime Considerations

1. Close Existing Agents Windows Before Launching
2. Always Launch Through the Dedicated Shortcut
3. Do Not Move or Rename the Script After Setup
4. Windows may cache shortcut icons. If the Agents icon does not update after reinstalling or updating the shortcut:
	1. Unpin the existing Agents shortcut from the taskbar.
	2. Open the Start Menu.
	3. Find `VS Code Agents`.
	4. Pin it to the taskbar again.
5. VS Code Updates: The launcher does not modify VS Code's executable files or internal application resources.However, VS Code updates may change its window creation behavior or resource directory layout.The script automatically searches for `sessions.ico`, but it is recommended to retest the launcher after major VS Code updates.If the script is stored inside the VS Code installation directory, consider keeping a backup because installation updates or repairs may affect custom files.

## Troubleshooting

| Problem | Suggested Solution |
|---|---|
| Agents Window does not open | Verify that the installed VS Code version supports the `--agents` argument. |
| Window detection times out | Close all existing Agents Windows and retry. |
| Agents Window uses the regular VS Code taskbar identity | Make sure it was launched through the dedicated shortcut. |
| Official Agents icon cannot be found | Verify that `sessions.ico` exists in the VS Code installation resources. |
| Start Menu shortcut does not work | Run the installation command again with `-InstallShortcut`. |
| Script cannot find VS Code | Verify the VS Code installation path and the `$CodeExe` configuration. |
| Taskbar icons are still grouped together | Verify that the shortcut and Agents Window use the same AppUserModelID. Unpin and re-pin the shortcut if necessary. |

## References

- [VS Code: Use the Agents Window](https://code.visualstudio.com/docs/agents/run/agents-window)
- [VS Code: Installing on Windows](https://code.visualstudio.com/docs/setup/windows)
- [Microsoft: Application User Model IDs](https://learn.microsoft.com/en-us/windows/win32/shell/appids)
- [Microsoft: SHGetPropertyStoreForWindow](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shgetpropertystoreforwindow)
