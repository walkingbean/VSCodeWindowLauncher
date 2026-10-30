
<#
.SYNOPSIS
    Opens the most recent regular VS Code Editor workspace and maximizes it.

.DESCRIPTION
    This launcher deliberately avoids VS Code's automatic last-window restoration.
    Instead, it reads history.recentlyOpenedPathsList from VS Code's shared SQLite
    database, skips the Agents Window workspace and non-workspace file entries, and
    opens the most recent existing Editor folder/workspace with --new-window.

    If no valid Editor workspace is recorded, it opens a blank Editor window.

    Existing Editor windows are activated and maximized instead of creating duplicates.
    Existing Agents windows are not forcibly closed, to avoid interrupting active work.

    -InstallShortcut creates/updates the per-user Start Menu shortcut "VS Code Editor".

.NOTES
    Script filename: code.exe.editor.ps1
    Intended location: <VS Code installation>\bin\code.exe.editor.ps1
    Requires 64-bit Windows PowerShell 5.1 and Windows winsqlite3.dll.
    Uses the existing VS Code installation and user data/profile.
    Agents history is filtered by the dedicated agent-sessions.code-workspace path
    and the "Agents Window" label.
#>

param(
    [switch]$InstallShortcut
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

$AppUserModelId = 'Microsoft.VisualStudioCode'
$ShortcutName = 'VS Code Editor'
$StartupTimeoutSeconds = 30
$MaximizeRetrySeconds = 6
$PollIntervalMilliseconds = 250
$LogPath = Join-Path $PSScriptRoot 'code.exe.editor.ps1.log'
$SharedDatabasePath = Join-Path $env:USERPROFILE '.vscode-shared\sharedStorage\state.vscdb'

function Write-Log {
    param([string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Convert-FileUriToLocalPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    try {
        if ($Value -match '^file:') {
            $uri = [System.Uri]$Value

            if (-not $uri.IsFile) {
                return $null
            }

            $localPath = $uri.LocalPath
        }
        elseif ([System.IO.Path]::IsPathRooted($Value)) {
            $localPath = $Value
        }
        else {
            return $null
        }

        $localPath = $localPath -replace '/', '\'

        # Normalize a possible leading slash before a Windows drive letter.
        if ($localPath -match '^\\[A-Za-z]:\\') {
            $localPath = $localPath.Substring(1)
        }

        return [System.IO.Path]::GetFullPath($localPath)
    }
    catch {
        return $null
    }
}

function Get-RecentEditorWorkspace {
    param([string]$DatabasePath)

    if (-not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)) {
        Write-Log "Shared history database not found: $DatabasePath"
        return $null
    }

    $historyJson = $null
    $lastReadError = $null
    $readSucceeded = $false

    # Retry briefly in case VS Code is finishing a database transaction.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $historyJson = [VSCodeEditorNativeV4]::ReadRecentHistory($DatabasePath)
            $readSucceeded = $true
            break
        }
        catch {
            $lastReadError = $_.Exception.Message
            Start-Sleep -Milliseconds 300
        }
    }

    # Do not silently treat a database read failure as an empty history.
    if (-not $readSucceeded) {
        throw "Unable to read VS Code recent-workspace history database after 5 attempts: $lastReadError"
    }

    if ([string]::IsNullOrWhiteSpace($historyJson)) {
        Write-Log 'The recent-workspace history key is absent or empty.'
        return $null
    }

    try {
        $history = $historyJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Recent-workspace history JSON is invalid: $($_.Exception.Message)"
    }

    if ($null -eq $history.entries) {
        throw 'Recent-workspace history does not contain the expected entries array.'
    }

    $entryIndex = 0

    foreach ($entry in @($history.entries)) {
        $entryIndex++

        if ($null -eq $entry) {
            continue
        }

        $label = [string]$entry.label
        $candidateUri = $null
        $candidateType = $null

        # Explicitly exclude the dedicated Agents Window item.
        if ($label -match '^Agents Window$') {
            Write-Log "Skipping recent-history entry $entryIndex (Agents Window label)."
            continue
        }

        # A regular multi-root workspace is stored as workspace.configPath.
        if ($entry.workspace -and $entry.workspace.configPath) {
            $candidateUri = [string]$entry.workspace.configPath
            $candidateType = 'WorkspaceFile'
        }
        # A single-folder Editor workspace is stored as folderUri.
        elseif ($entry.folderUri) {
            $candidateUri = [string]$entry.folderUri
            $candidateType = 'Folder'
        }
        else {
            # Ignore fileUri entries: they are individual files, not workspaces.
            Write-Log "Skipping recent-history entry $entryIndex (not a folder/workspace entry)."
            continue
        }

        $candidatePath = Convert-FileUriToLocalPath -Value $candidateUri

        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            Write-Log "Skipping entry $entryIndex (cannot convert URI): $candidateUri"
            continue
        }

        $leafName = [System.IO.Path]::GetFileName($candidatePath)

        if ($leafName -ieq 'agent-sessions.code-workspace') {
            Write-Log "Skipping Agents workspace path: $candidatePath"
            continue
        }

        if ($candidateType -eq 'Folder') {
            $exists = Test-Path -LiteralPath $candidatePath -PathType Container
        }
        else {
            $exists = Test-Path -LiteralPath $candidatePath -PathType Leaf
        }

        if (-not $exists) {
            Write-Log "Skipping missing recent Editor path: $candidatePath"
            continue
        }

        Write-Log "Selected recent Editor $candidateType (history entry $entryIndex): $candidatePath"

        return [PSCustomObject]@{
            Path = $candidatePath
            Type = $candidateType
            Label = $label
            HistoryIndex = $entryIndex
        }
    }

    Write-Log 'No valid non-Agents Editor workspace was found in recent history.'
    return $null
}

# -----------------------------------------------------------------------------
# Locate the existing VS Code installation.
# When this script is stored in <VS Code installation>\bin, Code.exe is one
# directory above the script directory.
# -----------------------------------------------------------------------------

$candidates = @()

if ($PSScriptRoot) {
    $installDirectory = Split-Path -Parent $PSScriptRoot

    if ($installDirectory) {
        $candidates += Join-Path $installDirectory 'Code.exe'
    }

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
    Where-Object {
        $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
    } |
    Select-Object -First 1

if (-not $CodeExe) {
    throw 'Cannot find Code.exe. Store this script in the VS Code bin directory or update the candidate paths.'
}

$CodeExe = (Resolve-Path -LiteralPath $CodeExe).Path
$CodeDirectory = Split-Path -Parent $CodeExe

if (-not [Environment]::Is64BitProcess) {
    throw 'Please run this script with 64-bit Windows PowerShell.'
}

# -----------------------------------------------------------------------------
# Native Windows APIs and Windows built-in SQLite (winsqlite3.dll).
# -----------------------------------------------------------------------------

if (-not ('VSCodeEditorNativeV4' -as [type])) {

    Add-Type -Language CSharp -TypeDefinition @'

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class VSCodeEditorWindowV4
{
    public IntPtr Handle { get; set; }
    public uint ProcessId { get; set; }
    public string ClassName { get; set; }
    public string Title { get; set; }
}

[StructLayout(LayoutKind.Sequential)]
public struct VSCodeEditorPropertyKeyV4
{
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Explicit, Size = 24)]
public struct VSCodeEditorPropVariantV4
{
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pwszVal;
}

[ComImport]
[Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface VSCodeEditorIPropertyStoreV4
{
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out VSCodeEditorPropertyKeyV4 key);
    [PreserveSig] int GetValue(ref VSCodeEditorPropertyKeyV4 key, out VSCodeEditorPropVariantV4 value);
    [PreserveSig] int SetValue(ref VSCodeEditorPropertyKeyV4 key, ref VSCodeEditorPropVariantV4 value);
    [PreserveSig] int Commit();
}

public static class VSCodeEditorNativeV4
{
    private const uint GW_OWNER = 4;
    private const int SW_SHOWMAXIMIZED = 3;
    private const uint SQLITE_OPEN_READONLY = 0x00000001;
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const uint GPS_READWRITE = 0x00000002;
    private const ushort VT_LPWSTR = 31;

    private static readonly Guid IID_IPropertyStore =
        new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    private static readonly VSCodeEditorPropertyKeyV4 PKEY_AppUserModel_ID =
        new VSCodeEditorPropertyKeyV4 {
            fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            pid = 5
        };

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(
        EnumWindowsProc callback,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(
        IntPtr hwnd,
        uint command
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(
        IntPtr hwnd,
        StringBuilder className,
        int maxCount
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(
        IntPtr hwnd,
        StringBuilder text,
        int maxCount
    );

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(
        IntPtr hwnd,
        out uint processId
    );

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetPropertyStoreFromParsingName(
        string path,
        IntPtr bindContext,
        uint flags,
        ref Guid iid,
        out VSCodeEditorIPropertyStoreV4 store
    );

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int PropVariantClear(
        ref VSCodeEditorPropVariantV4 propVariant
    );

    // Windows built-in SQLite API.
    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_open_v2",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(
        byte[] filename,
        out IntPtr database,
        uint flags,
        IntPtr vfs
    );

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_prepare_v2",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(
        IntPtr database,
        byte[] sql,
        int byteCount,
        out IntPtr statement,
        IntPtr tail
    );

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_step",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_column_text",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(
        IntPtr statement,
        int column
    );

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_column_bytes",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(
        IntPtr statement,
        int column
    );

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_errmsg",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr database);

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_finalize",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_close",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);

    [DllImport("winsqlite3.dll",
        EntryPoint = "sqlite3_busy_timeout",
        CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(
        IntPtr database,
        int milliseconds
    );

    private static string ReadUtf8Z(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
            return String.Empty;

        int length = 0;

        while (
            length < 65536 &&
            Marshal.ReadByte(pointer, length) != 0
        ) {
            length++;
        }

        byte[] bytes = new byte[length];
        Marshal.Copy(pointer, bytes, 0, length);

        return Encoding.UTF8.GetString(bytes);
    }

    public static string ReadRecentHistory(string databasePath)
    {
        IntPtr database = IntPtr.Zero;
        IntPtr statement = IntPtr.Zero;

        try
        {
            byte[] filename =
                Encoding.UTF8.GetBytes(databasePath + "\0");

            int rc = sqlite3_open_v2(
                filename,
                out database,
                SQLITE_OPEN_READONLY,
                IntPtr.Zero
            );

            if (rc != SQLITE_OK)
            {
                string error = database != IntPtr.Zero
                    ? ReadUtf8Z(sqlite3_errmsg(database))
                    : "SQLite could not open the database.";

                throw new Exception(
                    "Cannot open VS Code shared history database: " + error
                );
            }

            sqlite3_busy_timeout(database, 3000);

            const string query =
                "SELECT value FROM ItemTable " +
                "WHERE key = 'history.recentlyOpenedPathsList' LIMIT 1;";

            byte[] sql = Encoding.UTF8.GetBytes(query + "\0");

            rc = sqlite3_prepare_v2(
                database,
                sql,
                -1,
                out statement,
                IntPtr.Zero
            );

            if (rc != SQLITE_OK)
            {
                throw new Exception(
                    "SQLite query preparation failed: " +
                    ReadUtf8Z(sqlite3_errmsg(database))
                );
            }

            rc = sqlite3_step(statement);

            if (rc == SQLITE_DONE)
                return null;

            if (rc != SQLITE_ROW)
            {
                throw new Exception(
                    "SQLite query failed: " +
                    ReadUtf8Z(sqlite3_errmsg(database))
                );
            }

            IntPtr textPointer =
                sqlite3_column_text(statement, 0);

            int length =
                sqlite3_column_bytes(statement, 0);

            if (textPointer == IntPtr.Zero || length <= 0)
                return null;

            byte[] result = new byte[length];

            Marshal.Copy(
                textPointer,
                result,
                0,
                length
            );

            return Encoding.UTF8.GetString(result);
        }
        finally
        {
            if (statement != IntPtr.Zero)
                sqlite3_finalize(statement);

            if (database != IntPtr.Zero)
                sqlite3_close(database);
        }
    }

    private static HashSet<uint> GetCodeProcessIds(string exePath)
    {
        string expected = Path.GetFullPath(exePath);
        string processName = Path.GetFileNameWithoutExtension(expected);

        var ids = new HashSet<uint>();

        foreach (
            Process process in
            Process.GetProcessesByName(processName)
        )
        {
            try
            {
                string actual = Path.GetFullPath(
                    process.MainModule.FileName
                );

                if (
                    String.Equals(
                        actual,
                        expected,
                        StringComparison.OrdinalIgnoreCase
                    )
                ) {
                    ids.Add((uint)process.Id);
                }
            }
            catch { }
            finally {
                process.Dispose();
            }
        }

        return ids;
    }

    public static VSCodeEditorWindowV4[] GetCodeWindows(string exePath)
    {
        HashSet<uint> processIds =
            GetCodeProcessIds(exePath);

        var windows = new List<VSCodeEditorWindowV4>();

        EnumWindows(
            delegate(IntPtr hwnd, IntPtr lParam)
            {
                if (
                    !IsWindowVisible(hwnd) ||
                    GetWindow(hwnd, GW_OWNER) != IntPtr.Zero
                ) {
                    return true;
                }

                var className = new StringBuilder(256);

                GetClassName(
                    hwnd,
                    className,
                    className.Capacity
                );

                string classText = className.ToString();

                if (
                    !classText.StartsWith(
                        "Chrome_WidgetWin",
                        StringComparison.Ordinal
                    )
                ) {
                    return true;
                }

                uint pid;

                GetWindowThreadProcessId(
                    hwnd,
                    out pid
                );

                if (!processIds.Contains(pid))
                    return true;

                var title = new StringBuilder(1024);

                GetWindowText(
                    hwnd,
                    title,
                    title.Capacity
                );

                windows.Add(new VSCodeEditorWindowV4 {
                    Handle = hwnd,
                    ProcessId = pid,
                    ClassName = classText,
                    Title = title.ToString()
                });

                return true;
            },
            IntPtr.Zero
        );

        return windows.ToArray();
    }

    public static IntPtr GetForegroundWindowHandle()
    {
        return GetForegroundWindow();
    }

    public static void MaximizeAndActivate(IntPtr hwnd)
    {
        if (!IsWindow(hwnd))
            return;

        ShowWindowAsync(hwnd, SW_SHOWMAXIMIZED);
        ShowWindow(hwnd, SW_SHOWMAXIMIZED);
        SetForegroundWindow(hwnd);
    }

    public static void SetShortcutAppUserModelId(
        string shortcutPath,
        string appId
    )
    {
        VSCodeEditorIPropertyStoreV4 store = null;
        IntPtr stringMemory = IntPtr.Zero;

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

            if (hr < 0)
                Marshal.ThrowExceptionForHR(hr);

            stringMemory = Marshal.StringToCoTaskMemUni(appId);

            var value = new VSCodeEditorPropVariantV4 {
                vt = VT_LPWSTR,
                pwszVal = stringMemory
            };

            var key = PKEY_AppUserModel_ID;

            hr = store.SetValue(
                ref key,
                ref value
            );

            if (hr < 0)
                Marshal.ThrowExceptionForHR(hr);

            hr = store.Commit();

            if (hr < 0)
                Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            if (stringMemory != IntPtr.Zero)
            {
                var value = new VSCodeEditorPropVariantV4 {
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
# Install / update the Start Menu shortcut.
# -----------------------------------------------------------------------------

if ($InstallShortcut) {

    $programs = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Programs
    )

    $shortcutPath = Join-Path $programs (
        $ShortcutName + '.lnk'
    )

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
    $shortcut.IconLocation = "$CodeExe,0"

    $shortcut.Description =
        'Open the most recent VS Code Editor workspace, or a blank Editor if none is available'

    $shortcut.Save()

    [VSCodeEditorNativeV4]::SetShortcutAppUserModelId(
        $shortcutPath,
        $AppUserModelId
    )

    Write-Host 'Created/updated Start Menu shortcut:' -ForegroundColor Green
    Write-Host $shortcutPath
    Write-Host "AppUserModelID: $AppUserModelId"
    Write-Host "Icon: $CodeExe"

    Write-Host 'Pin "VS Code Editor" from the Start Menu to the taskbar.' -ForegroundColor Yellow

    exit 0
}

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------

try {

    Add-Content -LiteralPath $LogPath -Value (
        "`r`n=== VS Code Editor launcher started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    ) -Encoding UTF8

    Write-Log "Script: $PSCommandPath"
    Write-Log "Code.exe: $CodeExe"
    Write-Log "History database: $SharedDatabasePath"

    $existingWindows = @(
        [VSCodeEditorNativeV4]::GetCodeWindows($CodeExe)
    )

    foreach ($window in $existingWindows) {
        Write-Log (
            "Existing window HWND=0x{0:X} PID={1} TITLE=[{2}]" -f
            $window.Handle.ToInt64(),
            $window.ProcessId,
            $window.Title
        )
    }

    # If an Editor window is already open, activate and maximize it instead of
    # creating another Editor window. A live Agents window is left untouched.
    $existingEditors = @(
        $existingWindows | Where-Object {
            -not [string]::Equals(
                $_.Title.Trim(),
                'Agents',
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    )

    if ($existingEditors.Count -gt 0) {

        $foreground = [VSCodeEditorNativeV4]::GetForegroundWindowHandle()
        $foregroundValue = [long]$foreground.ToInt64()

        $targetEditor = $existingEditors |
            Where-Object {
                [long]$_.Handle.ToInt64() -eq $foregroundValue
            } |
            Select-Object -First 1

        if (-not $targetEditor) {
            $targetEditor = $existingEditors |
                Select-Object -First 1
        }

        [VSCodeEditorNativeV4]::MaximizeAndActivate(
            $targetEditor.Handle
        )

        Write-Log (
            "Activated existing Editor HWND=0x{0:X} TITLE=[{1}]" -f
            $targetEditor.Handle.ToInt64(),
            $targetEditor.Title
        )

        Write-Log 'Launcher finished by activating an existing Editor window.'
        exit 0
    }

    # No Editor window is currently open. Find the most recent valid Editor
    # workspace, skipping the Agents Window and individual-file history entries.
    $recentWorkspace = Get-RecentEditorWorkspace `
        -DatabasePath $SharedDatabasePath

    if ($recentWorkspace) {

        $launchPath = $recentWorkspace.Path

        $launchArguments =
            '--new-window "' +
            $launchPath.Replace('"', '\"') +
            '"'

        Write-Log "Launching most recent Editor workspace: $launchPath"
        Write-Log "Workspace type: $($recentWorkspace.Type); history index: $($recentWorkspace.HistoryIndex)"
    }
    else {

        # User-requested behavior: if no valid Editor workspace exists,
        # open a blank Editor window without displaying a prompt.
        $launchPath = $null
        $launchArguments = '--new-window'

        Write-Log 'No valid Editor workspace found. Opening a blank Editor window.'
    }

    # Record current window handles so that the newly-created Editor window
    # can be identified even when an Agents window is already running.
    $beforeHandles = New-Object 'System.Collections.Generic.HashSet[long]'

    foreach ($window in $existingWindows) {
        [void]$beforeHandles.Add(
            [long]$window.Handle.ToInt64()
        )
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo

    $startInfo.FileName = $CodeExe
    $startInfo.WorkingDirectory = $CodeDirectory
    $startInfo.Arguments = $launchArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $startedProcess = [System.Diagnostics.Process]::Start($startInfo)

    if ($startedProcess) {
        $startedProcess.Dispose()
    }

    Write-Log "Started Code.exe with arguments: $launchArguments"

    # Wait for the new Editor top-level window.
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)

    $targetHandle = [IntPtr]::Zero
    $targetTitle = $null

    while ((Get-Date) -lt $deadline) {

        $currentWindows = @(
            [VSCodeEditorNativeV4]::GetCodeWindows($CodeExe)
        )

        foreach ($window in $currentWindows) {

            $handleValue = [long]$window.Handle.ToInt64()

            if ($beforeHandles.Contains($handleValue)) {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($window.Title)) {
                continue
            }

            if (
                [string]::Equals(
                    $window.Title.Trim(),
                    'Agents',
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                # An explicitly requested Editor launch should not create
                # an Agents window. Do not mistake it for an Editor window.
                Write-Log (
                    "Unexpected new Agents window detected; leaving it untouched. HWND=0x{0:X}" -f
                    $handleValue
                )

                continue
            }

            $targetHandle = $window.Handle
            $targetTitle = $window.Title
            break
        }

        if ($targetHandle -ne [IntPtr]::Zero) {
            break
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }

    if ($targetHandle -eq [IntPtr]::Zero) {
        throw "The Editor window was not detected within $StartupTimeoutSeconds seconds. Check the log: $LogPath"
    }

    Write-Log (
        "New Editor window detected: HWND=0x{0:X} TITLE=[{1}]" -f
        $targetHandle.ToInt64(),
        $targetTitle
    )

    # Reapply maximization for several seconds because VS Code may finish
    # restoring editor layout after the native window first appears.
    $maximizeDeadline = (Get-Date).AddSeconds($MaximizeRetrySeconds)

    while ((Get-Date) -lt $maximizeDeadline) {

        [VSCodeEditorNativeV4]::MaximizeAndActivate(
            $targetHandle
        )

        Start-Sleep -Milliseconds 300
    }

    Write-Log (
        "Editor maximized and activated: HWND=0x{0:X}" -f
        $targetHandle.ToInt64()
    )

    Write-Log 'Launcher completed successfully.'
}
catch {

    try {
        Write-Log ("ERROR: " + $_.Exception.ToString())
    }
    catch {}

    $message = $_.Exception.ToString() +
        "`r`n`r`nLog file: $LogPath"

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
