
<#
.SYNOPSIS
    Launches the VS Code Agents Window and assigns it a separate Windows taskbar identity.

.DESCRIPTION
    - Uses the existing VS Code installation and existing user data/profile.
    - Starts VS Code with --agents.
    - Detects the newly-created VS Code top-level window and assigns a window-level
      AppUserModelID through SHGetPropertyStoreForWindow.
    - -InstallShortcut creates/updates a Start Menu shortcut with the same AppUserModelID
      and the official VS Code Agents Window icon (sessions.ico).

.NOTES
    Run with 64-bit Windows PowerShell 5.1.
    This is an unsupported wrapper workaround. Close any pre-existing Agents Window
    before launching through this shortcut so the new window can be identified reliably.
#>

param(
    [switch]$InstallShortcut
)

$ErrorActionPreference = 'Stop'

# ===================== User settings =====================

# Prefer Code.exe beside this script.
$CodeExe = Join-Path $PSScriptRoot 'Code.exe'

# Fall back to common VS Code installation locations if necessary.
if (-not (Test-Path -LiteralPath $CodeExe)) {
    $candidates = @()

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
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}

# AppUserModelID shared by the window and the Start Menu shortcut.
$AppUserModelId = 'Local.VSCode.Agents'

$ShortcutName = 'VS Code Agents'

$WindowDetectionTimeoutMs = 30000

# ==========================================================

if (-not $CodeExe -or -not (Test-Path -LiteralPath $CodeExe)) {
    throw "Cannot find Code.exe. Put this script beside Code.exe or edit `$CodeExe near the top of this script."
}

$CodeExe = (Resolve-Path -LiteralPath $CodeExe).Path
$CodeDirectory = Split-Path -Parent $CodeExe

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this script with 64-bit Windows PowerShell, not 32-bit PowerShell.'
}

# ==========================================================
# Locate official Agents Window icon: sessions.ico
#
# Supports:
# 1. Standard resource layout.
# 2. Hash-named directory layout, e.g.:
#    Microsoft VS Code\2c33b50b16\resources\app\resources\win32\sessions.ico
# 3. Future nested directory layouts.
# ==========================================================

$AgentsIcon = $null

$iconCandidates = @(
    (Join-Path $CodeDirectory 'resources\app\resources\win32\sessions.ico'),
    (Join-Path $CodeDirectory 'resources\win32\sessions.ico')
)

# Search immediate subdirectories, including hash-named directories.
$versionedDirectories = Get-ChildItem `
    -LiteralPath $CodeDirectory `
    -Directory `
    -ErrorAction SilentlyContinue

foreach ($versionedDirectory in $versionedDirectories) {

    $iconCandidates += Join-Path `
        $versionedDirectory.FullName `
        'resources\app\resources\win32\sessions.ico'

    $iconCandidates += Join-Path `
        $versionedDirectory.FullName `
        'resources\win32\sessions.ico'
}

# Find the first existing candidate.
$AgentsIcon = $iconCandidates |
    Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } |
    Select-Object -First 1

# Last-resort recursive search for future directory layouts.
if (-not $AgentsIcon) {

    $foundIcon = Get-ChildItem `
        -LiteralPath $CodeDirectory `
        -Filter 'sessions.ico' `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($foundIcon) {
        $AgentsIcon = $foundIcon.FullName
    }
}

# ==========================================================
# Windows API implementation
# ==========================================================

if (-not ('VscodeAgentTaskbarNative' -as [type])) {

    Add-Type -Language CSharp -TypeDefinition @'

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

[StructLayout(LayoutKind.Sequential)]
public struct VSCodePropertyKey
{
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
public struct VSCodePropVariant
{
    [FieldOffset(0)]
    public ushort vt;

    [FieldOffset(8)]
    public IntPtr pwszVal;
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface VSCodeIPropertyStore
{
    [PreserveSig]
    int GetCount(out uint cProps);

    [PreserveSig]
    int GetAt(uint iProp, out VSCodePropertyKey pkey);

    [PreserveSig]
    int GetValue(
        ref VSCodePropertyKey key,
        out VSCodePropVariant pv
    );

    [PreserveSig]
    int SetValue(
        ref VSCodePropertyKey key,
        ref VSCodePropVariant pv
    );

    [PreserveSig]
    int Commit();
}

public static class VscodeAgentTaskbarNative
{
    private const uint GW_OWNER = 4;

    private const uint GPS_READWRITE = 0x00000002;

    private const ushort VT_LPWSTR = 31;

    private const string WindowClassPrefix = "Chrome_WidgetWin";

    private static readonly Guid IID_IPropertyStore =
        new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    private static readonly VSCodePropertyKey PKEY_AppUserModel_ID =
        new VSCodePropertyKey {
            fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            pid = 5
        };

    private delegate bool EnumWindowsProc(
        IntPtr hwnd,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(
        EnumWindowsProc callback,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(
        IntPtr hwnd
    );

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(
        IntPtr hwnd,
        uint command
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hwnd,
        System.Text.StringBuilder className,
        int maxCount
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr hwnd,
        out uint processId
    );

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool IsWindow(
        IntPtr hwnd
    );

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(
        IntPtr hwnd,
        int command
    );

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(
        IntPtr hwnd
    );

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetPropertyStoreForWindow(
        IntPtr hwnd,
        ref Guid riid,
        out VSCodeIPropertyStore propertyStore
    );

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetPropertyStoreFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        IntPtr bindContext,
        uint flags,
        ref Guid riid,
        out VSCodeIPropertyStore propertyStore
    );

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int PropVariantClear(
        ref VSCodePropVariant propVariant
    );

    private static void ThrowIfFailed(
        int hr,
        string operation
    )
    {
        if (hr < 0)
            Marshal.ThrowExceptionForHR(hr, new IntPtr(-1));
    }

    private static void SetAppId(
        VSCodeIPropertyStore store,
        string appId
    )
    {
        VSCodePropVariant pv = new VSCodePropVariant();

        pv.vt = VT_LPWSTR;

        pv.pwszVal = Marshal.StringToCoTaskMemUni(appId);

        try
        {
            VSCodePropertyKey key = PKEY_AppUserModel_ID;

            int hr = store.SetValue(
                ref key,
                ref pv
            );

            ThrowIfFailed(
                hr,
                "IPropertyStore.SetValue"
            );
        }
        finally
        {
            PropVariantClear(ref pv);
        }
    }

    public static void SetShortcutAppId(
        string shortcutPath,
        string appId
    )
    {
        VSCodeIPropertyStore store = null;

        try
        {
            Guid iid = IID_IPropertyStore;

            int hr = SHGetPropertyStoreFromParsingName(
                shortcutPath,
                IntPtr.Zero,
                GPS_READWRITE,
                ref iid,
                out store
            );

            ThrowIfFailed(
                hr,
                "SHGetPropertyStoreFromParsingName"
            );

            SetAppId(store, appId);

            hr = store.Commit();

            ThrowIfFailed(
                hr,
                "IPropertyStore.Commit for shortcut"
            );
        }
        finally
        {
            if (store != null)
                Marshal.ReleaseComObject(store);
        }
    }

    public static void SetWindowAppId(
        IntPtr hwnd,
        string appId
    )
    {
        VSCodeIPropertyStore store = null;

        try
        {
            Guid iid = IID_IPropertyStore;

            int hr = SHGetPropertyStoreForWindow(
                hwnd,
                ref iid,
                out store
            );

            ThrowIfFailed(
                hr,
                "SHGetPropertyStoreForWindow"
            );

            SetAppId(store, appId);

            // Window property store changes take effect immediately.
        }
        finally
        {
            if (store != null)
                Marshal.ReleaseComObject(store);
        }
    }

    private static HashSet<uint> GetCodeProcessIds(
        string exePath
    )
    {
        string expected = Path.GetFullPath(exePath);

        var ids = new HashSet<uint>();

        string processName =
            Path.GetFileNameWithoutExtension(expected);

        foreach (
            Process process in
            Process.GetProcessesByName(processName)
        )
        {
            try
            {
                string actual =
                    Path.GetFullPath(process.MainModule.FileName);

                if (
                    String.Equals(
                        actual,
                        expected,
                        StringComparison.OrdinalIgnoreCase
                    )
                )
                {
                    ids.Add((uint)process.Id);
                }
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

    public static HashSet<IntPtr> GetCodeWindows(
        string exePath
    )
    {
        HashSet<uint> processIds =
            GetCodeProcessIds(exePath);

        var handles = new HashSet<IntPtr>();

        EnumWindows(
            delegate(IntPtr hwnd, IntPtr lParam)
            {
                if (
                    !IsWindowVisible(hwnd) ||
                    GetWindow(hwnd, GW_OWNER) != IntPtr.Zero
                )
                {
                    return true;
                }

                var className =
                    new System.Text.StringBuilder(128);

                GetClassName(
                    hwnd,
                    className,
                    className.Capacity
                );

                if (
                    !className.ToString().StartsWith(
                        WindowClassPrefix,
                        StringComparison.Ordinal
                    )
                )
                {
                    return true;
                }

                uint pid;

                GetWindowThreadProcessId(
                    hwnd,
                    out pid
                );

                if (processIds.Contains(pid))
                    handles.Add(hwnd);

                return true;
            },
            IntPtr.Zero
        );

        return handles;
    }

    public static IntPtr LaunchAgentsAndTag(
        string exePath,
        string appId,
        int timeoutMilliseconds
    )
    {
        HashSet<IntPtr> before =
            GetCodeWindows(exePath);

        var startInfo = new ProcessStartInfo();

        startInfo.FileName = exePath;
        startInfo.Arguments = "--agents";
        startInfo.WorkingDirectory =
            Path.GetDirectoryName(exePath);

        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;

        Process launched = Process.Start(startInfo);

        if (launched != null)
            launched.Dispose();

        var timer = Stopwatch.StartNew();

        Exception lastError = null;

        while (
            timer.ElapsedMilliseconds <
            timeoutMilliseconds
        )
        {
            HashSet<IntPtr> current =
                GetCodeWindows(exePath);

            var candidates = new List<IntPtr>();

            foreach (IntPtr hwnd in current)
            {
                if (!before.Contains(hwnd))
                    candidates.Add(hwnd);
            }

            if (candidates.Count > 0)
            {
                IntPtr foreground =
                    GetForegroundWindow();

                IntPtr target =
                    candidates.Contains(foreground)
                    ? foreground
                    : candidates[0];

                if (IsWindow(target))
                {
                    try
                    {
                        SetWindowAppId(
                            target,
                            appId
                        );

                        ShowWindow(
                            target,
                            9
                        ); // SW_RESTORE

                        SetForegroundWindow(target);

                        return target;
                    }
                    catch (Exception ex)
                    {
                        lastError = ex;
                    }
                }
            }

            Thread.Sleep(200);
        }

        string message =
            "No new VS Code top-level window was detected within " +
            timeoutMilliseconds + " ms.";

        if (lastError != null)
        {
            message +=
                Environment.NewLine +
                "Last error: " +
                lastError.Message;
        }

        message +=
            Environment.NewLine +
            Environment.NewLine +
            "Close any existing Agents Window, then launch again. " +
            "Keep the normal editor open or closed as preferred. " +
            "The launcher can only tag a newly-created window; " +
            "it cannot reliably identify an Agents Window that " +
            "was opened earlier through VS Code.";

        throw new TimeoutException(message);
    }
}

'@
}

# ==========================================================
# Install / Update Start Menu shortcut
# ==========================================================

if ($InstallShortcut) {

    $programs = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Programs
    )

    $shortcutPath = Join-Path `
        $programs `
        ($ShortcutName + '.lnk')

    $powershellExe = Join-Path $PSHOME 'powershell.exe'

    $shell = New-Object -ComObject WScript.Shell

    $shortcut = $shell.CreateShortcut(
        $shortcutPath
    )

    $shortcut.TargetPath = $powershellExe

    $shortcut.Arguments =
        '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $PSCommandPath + '"'

    $shortcut.WorkingDirectory = $CodeDirectory

    # Use official Agents Window icon when found.
    if ($AgentsIcon) {

        $shortcut.IconLocation = "$AgentsIcon,0"

    }
    else {

        # Fallback to the standard VS Code icon.
        $shortcut.IconLocation = "$CodeExe,0"

        Write-Warning (
            "The official sessions.ico was not found. " +
            "Using the standard VS Code icon instead."
        )
    }

    $shortcut.Description =
        'Open Visual Studio Code Agents Window'

    $shortcut.Save()

    # Give the shortcut the same AppUserModelID as the Agents Window.
    [VscodeAgentTaskbarNative]::SetShortcutAppId(
        $shortcutPath,
        $AppUserModelId
    )

    Write-Host ''
    Write-Host 'Created/updated Start Menu shortcut:' -ForegroundColor Green
    Write-Host $shortcutPath

    Write-Host "AppUserModelID: $AppUserModelId"

    if ($AgentsIcon) {

        Write-Host ''
        Write-Host 'Agents icon:' -ForegroundColor Green
        Write-Host $AgentsIcon

    }
    else {

        Write-Warning 'Using standard VS Code icon.'
    }

    Write-Host ''
    Write-Host 'Now pin "VS Code Agents" from the Start Menu to the taskbar.' -ForegroundColor Yellow

    exit 0
}

# ==========================================================
# Launch Agents Window and assign its window-level AppUserModelID
# ==========================================================

try {

    $hwnd = [VscodeAgentTaskbarNative]::LaunchAgentsAndTag(
        $CodeExe,
        $AppUserModelId,
        $WindowDetectionTimeoutMs
    )

    Write-Host (
        'Agents Window tagged successfully. HWND=0x{0:X}' -f
        $hwnd.ToInt64()
    )
}
catch {

    try {

        Add-Type -AssemblyName System.Windows.Forms

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.ToString(),
            'VS Code Agents launcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null

    }
    catch {

        Write-Error $_
    }

    exit 1
}
