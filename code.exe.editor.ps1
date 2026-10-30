<#
.SYNOPSIS
    Launches the regular VS Code editor and closes Agents Windows restored by that launch.

.DESCRIPTION
    This launcher is intended to be used for the regular VS Code taskbar shortcut.
    It starts the existing Code.exe WITHOUT --new-window, so VS Code can restore its
    previous editor folders/workspaces. It then detects newly-created VS Code top-level
    windows whose title is exactly "Agents" and sends them WM_CLOSE.

    Existing VS Code windows that were already open before this launcher ran are not
    closed. The separate code.exe.agents.ps1 launcher is not modified by this script.

    -InstallShortcut creates a Start Menu shortcut named "VS Code Editor" and assigns
    the standard VS Code AppUserModelID so its windows can remain grouped with VS Code.

.NOTES
    Run with 64-bit Windows PowerShell 5.1.
    The Agents-window identification is based on the observed window title "Agents" and
    Chrome_WidgetWin* class. VS Code updates may change this behavior; retest after updates.
#>

param(
    [switch]$InstallShortcut
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Locate the existing VS Code installation.
# When this script is stored in <VS Code install>\bin, Code.exe is one level above.
# -----------------------------------------------------------------------------

$candidates = @()
$scriptParent = Split-Path -Parent $PSScriptRoot

if ($scriptParent) {
    $candidates += Join-Path $scriptParent 'Code.exe'
}
if ($PSScriptRoot) {
    $candidates += Join-Path $PSScriptRoot 'Code.exe'
}
if ($env:LOCALAPPDATA) {
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
}
if ($env:ProgramFiles) {
    $candidates += Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
}
if (${env:ProgramFiles(x86)}) {
    $candidates += Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\Code.exe'
}

$CodeExe = $candidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -First 1

if (-not $CodeExe) {
    throw 'Cannot find Code.exe. Store this script in the VS Code bin directory or update the candidate paths.'
}

$CodeExe = (Resolve-Path -LiteralPath $CodeExe).Path
$CodeDirectory = Split-Path -Parent $CodeExe

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script with 64-bit Windows PowerShell.'
}

# -----------------------------------------------------------------------------
# Native Windows window enumeration and shortcut AppUserModelID support.
# -----------------------------------------------------------------------------

if (-not ('VSCodeEditorLauncherNative' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class VSCodeEditorWindowInfo
{
    public IntPtr Handle { get; set; }
    public uint ProcessId { get; set; }
    public string ClassName { get; set; }
    public string Title { get; set; }
}

[StructLayout(LayoutKind.Sequential)]
public struct VSCodeEditorPropertyKey
{
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
public struct VSCodeEditorPropVariant
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pwszVal;
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface VSCodeEditorIPropertyStore
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out VSCodeEditorPropertyKey key);
    [PreserveSig] int GetValue(ref VSCodeEditorPropertyKey key, out VSCodeEditorPropVariant value);
    [PreserveSig] int SetValue(ref VSCodeEditorPropertyKey key, ref VSCodeEditorPropVariant value);
    [PreserveSig] int Commit();
}

public static class VSCodeEditorLauncherNative
{
    private const uint GW_OWNER = 4;
    private const uint WM_CLOSE = 0x0010;
    private const uint GPS_READWRITE = 0x00000002;
    private const ushort VT_LPWSTR = 31;

    private static readonly Guid IID_IPropertyStore =
        new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    private static readonly VSCodeEditorPropertyKey PKEY_AppUserModel_ID =
        new VSCodeEditorPropertyKey {
            fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            pid = 5
        };

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetPropertyStoreFromParsingName(
        string path, IntPtr bindContext, uint flags,
        ref Guid iid, out VSCodeEditorIPropertyStore store);

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int PropVariantClear(ref VSCodeEditorPropVariant propVariant);

    private static HashSet<uint> GetCodeProcessIds(string exePath)
    {
        string expected = Path.GetFullPath(exePath);
        string processName = Path.GetFileNameWithoutExtension(expected);
        var ids = new HashSet<uint>();

        foreach (Process process in Process.GetProcessesByName(processName))
        {
            try
            {
                string actual = Path.GetFullPath(process.MainModule.FileName);
                if (String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
                    ids.Add((uint)process.Id);
            }
            catch
            {
                // Ignore processes whose executable path cannot be queried.
            }
            finally
            {
                process.Dispose();
            }
        }

        return ids;
    }

    public static VSCodeEditorWindowInfo[] GetCodeWindows(string exePath)
    {
        HashSet<uint> processIds = GetCodeProcessIds(exePath);
        var windows = new List<VSCodeEditorWindowInfo>();

        EnumWindows(delegate(IntPtr hwnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) != IntPtr.Zero)
                return true;

            var className = new StringBuilder(256);
            GetClassName(hwnd, className, className.Capacity);

            if (!className.ToString().StartsWith("Chrome_WidgetWin", StringComparison.Ordinal))
                return true;

            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (!processIds.Contains(pid))
                return true;

            var title = new StringBuilder(1024);
            GetWindowText(hwnd, title, title.Capacity);

            windows.Add(new VSCodeEditorWindowInfo {
                Handle = hwnd,
                ProcessId = pid,
                ClassName = className.ToString(),
                Title = title.ToString()
            });

            return true;
        }, IntPtr.Zero);

        return windows.ToArray();
    }

    public static bool CloseWindow(IntPtr hwnd)
    {
        if (!IsWindow(hwnd))
            return true;

        // WM_CLOSE requests a normal window close; it does not terminate Code.exe.
        return PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }

    public static void SetShortcutAppUserModelId(string shortcutPath, string appId)
    {
        VSCodeEditorIPropertyStore store = null;
        IntPtr stringMemory = IntPtr.Zero;

        try
        {
            Guid iid = IID_IPropertyStore;
            int hr = SHGetPropertyStoreFromParsingName(
                shortcutPath, IntPtr.Zero, GPS_READWRITE, ref iid, out store);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);

            stringMemory = Marshal.StringToCoTaskMemUni(appId);
            VSCodeEditorPropVariant value = new VSCodeEditorPropVariant {
                vt = VT_LPWSTR,
                pwszVal = stringMemory
            };

            VSCodeEditorPropertyKey key = PKEY_AppUserModel_ID;
            hr = store.SetValue(ref key, ref value);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);

            hr = store.Commit();
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            if (stringMemory != IntPtr.Zero)
            {
                var value = new VSCodeEditorPropVariant {
                    vt = VT_LPWSTR,
                    pwszVal = stringMemory
                };
                PropVariantClear(ref value);
            }

            if (store != null)
                Marshal.ReleaseComObject(store);
        }
    }
}
'@
}

# -----------------------------------------------------------------------------
# Install a dedicated regular-Editor shortcut.
# It uses the same AppUserModelID as the normal VS Code application.
# -----------------------------------------------------------------------------

if ($InstallShortcut) {
    $programs = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $shortcutPath = Join-Path $programs 'VS Code Editor.lnk'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellExe
    $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $shortcut.WorkingDirectory = $CodeDirectory
    $shortcut.IconLocation = "$CodeExe,0"
    $shortcut.Description = 'Open Visual Studio Code Editor and restore editor workspaces without restored Agents windows'
    $shortcut.Save()

    [VSCodeEditorLauncherNative]::SetShortcutAppUserModelId(
        $shortcutPath,
        'Microsoft.VisualStudioCode'
    )

    Write-Host 'Created/updated Start Menu shortcut:' -ForegroundColor Green
    Write-Host $shortcutPath
    Write-Host 'AppUserModelID: Microsoft.VisualStudioCode'
    Write-Host "Icon: $CodeExe"
    Write-Host 'Pin "VS Code Editor" from the Start Menu to the taskbar.' -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# Normal launch: preserve VS Code's own workspace restoration, then close only
# newly-restored windows whose title is exactly "Agents".
# -----------------------------------------------------------------------------

try {
    $beforeWindows = @([VSCodeEditorLauncherNative]::GetCodeWindows($CodeExe))
    $beforeHandles = New-Object 'System.Collections.Generic.HashSet[long]'

    foreach ($window in $beforeWindows) {
        [void]$beforeHandles.Add([long]$window.Handle.ToInt64())
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $CodeExe
    $startInfo.WorkingDirectory = $CodeDirectory
    $startInfo.Arguments = ''  # Intentionally no --new-window: preserve normal workspace restoration.
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $startedProcess = [System.Diagnostics.Process]::Start($startInfo)
    if ($startedProcess) { $startedProcess.Dispose() }

    # If VS Code windows were already open, this invocation is being forwarded to
    # the running instance. Do not close an Agents window that predates this launch.
    if ($beforeWindows.Count -gt 0) {
        exit 0
    }

    $processedHandles = New-Object 'System.Collections.Generic.HashSet[long]'
    $editorWindowSeen = $false
    $firstEditorWindowAt = $null
    $agentWindowsClosed = 0
    $lastAgentCloseAt = $null
    $lastNewWindowAt = [DateTime]::UtcNow
    $deadline = [DateTime]::UtcNow.AddSeconds(45)

    while ([DateTime]::UtcNow -lt $deadline) {
        $currentWindows = @([VSCodeEditorLauncherNative]::GetCodeWindows($CodeExe))
        $newWindowFound = $false

        foreach ($window in $currentWindows) {
            $handleValue = [long]$window.Handle.ToInt64()

            if ($beforeHandles.Contains($handleValue) -or
                $processedHandles.Contains($handleValue)) {
                continue
            }

            # A new window can briefly have an empty title while it is initializing.
            if ([string]::IsNullOrWhiteSpace($window.Title)) {
                continue
            }

            [void]$processedHandles.Add($handleValue)
            $newWindowFound = $true

            if ([string]::Equals(
                $window.Title.Trim(),
                'Agents',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                [void][VSCodeEditorLauncherNative]::CloseWindow($window.Handle)
                $agentWindowsClosed++
                $lastAgentCloseAt = [DateTime]::UtcNow
            }
            else {
                if (-not $editorWindowSeen) {
                    $firstEditorWindowAt = [DateTime]::UtcNow
                }
                $editorWindowSeen = $true
            }
        }

        if ($newWindowFound) {
            $lastNewWindowAt = [DateTime]::UtcNow
        }

        # Wait at least 8 seconds after the first Editor window appears, and also
        # require 3 seconds without newly-created windows. This gives delayed
        # restored Agents windows time to appear so they can be filtered as well.
        if ($editorWindowSeen -and
            ([DateTime]::UtcNow - $firstEditorWindowAt).TotalSeconds -ge 8 -and
            ([DateTime]::UtcNow - $lastNewWindowAt).TotalSeconds -ge 3) {
            break
        }

        # If only an Agents window was restored, do not wait for the full timeout.
        # Give the normal Editor restore a short grace period before using the fallback.
        if (-not $editorWindowSeen -and $lastAgentCloseAt -and
            ([DateTime]::UtcNow - $lastAgentCloseAt).TotalSeconds -ge 12) {
            break
        }

        Start-Sleep -Milliseconds 250
    }

    if ($agentWindowsClosed -gt 0) {
        Write-Host "Closed $agentWindowsClosed restored Agents window(s)."
    }

    if (-not $editorWindowSeen) {
        if ($agentWindowsClosed -gt 0) {
            # No Editor workspace was restored. Open a blank Editor as a fallback;
            # this is only used when the normal restore produced Agents but no Editor.
            $fallback = New-Object System.Diagnostics.ProcessStartInfo
            $fallback.FileName = $CodeExe
            $fallback.Arguments = '--new-window'
            $fallback.WorkingDirectory = $CodeDirectory
            $fallback.UseShellExecute = $false
            $fallback.CreateNoWindow = $true
            [void][System.Diagnostics.Process]::Start($fallback)
            Write-Warning 'No Editor window was restored, so a new blank Editor window was opened.'
        }
        else {
            Write-Warning 'No restored Editor window was detected within 45 seconds. No existing window was forcibly terminated.'
        }
    }
}
catch {
    $message = $_.Exception.ToString()
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            'VS Code Editor launcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    catch {
        Write-Error $message
    }
    exit 1
}
