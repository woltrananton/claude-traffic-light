# Traffic light for Claude Code in the Windows taskbar (system tray).
# Reads the session files that hook.sh writes to ~/.claude/trafficlight/.
# Each session gets its own dot with a label (e.g. T1) that also shows in the status line.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Native -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr hIcon);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
'@

# Only one instance at a time
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ClaudeCodeTrafficLight', [ref]$created)
if (-not $created) { exit }

$stateDir = Join-Path $env:USERPROFILE '.claude\trafficlight'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$colors = @{
    red    = [System.Drawing.Color]::FromArgb(230, 40, 40)
    yellow = [System.Drawing.Color]::FromArgb(245, 190, 20)
    green  = [System.Drawing.Color]::FromArgb(40, 190, 70)
    off    = [System.Drawing.Color]::FromArgb(120, 120, 120)
}
$labels = @{
    red    = 'Needs you'
    yellow = 'Working'
    green  = 'Done'
    off    = 'No active session'
}

# Icons are cached per color + letter
$iconCache = @{}
function Get-DotIcon([string]$state, [string]$letter) {
    if (-not $colors.ContainsKey($state)) { $state = 'off' }
    $key = "$state|$letter"
    if ($iconCache.ContainsKey($key)) { return $iconCache[$key] }

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $colors[$state]
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(160, 0, 0, 0)), 2
    $g.DrawEllipse($pen, 1, 1, 30, 30)
    if ($letter) {
        $size = switch ($letter.Length) { 1 { 18 } 2 { 15 } default { 11 } }
        $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        # Black text on yellow, white on the others, for best contrast
        $textColor = if ($state -eq 'yellow') { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        $textBrush = New-Object System.Drawing.SolidBrush $textColor
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $g.DrawString($letter, $font, $textBrush, (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $fmt)
        $font.Dispose(); $textBrush.Dispose(); $fmt.Dispose()
    }
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon).Clone()
    [Native.Win32]::DestroyIcon($hIcon) | Out-Null
    $bmp.Dispose()
    $iconCache[$key] = $icon
    return $icon
}

# Reads a session file without locking it. Get-Content opens the file without FileShare.Delete, which
# makes hook.sh's "mv" (replacing the file) fail if the tray app happens to read at the same time.
function Read-StateLines([string]$path) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
    } finally { $fs.Dispose() }
    return @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Get-Sessions {
    $list = @()
    foreach ($f in Get-ChildItem -Path $stateDir -File -ErrorAction SilentlyContinue) {
        if ($f.Extension -eq '.tmp') { continue }
        # Forget sessions not heard from in 12 hours (e.g. closed with the X button)
        if ($f.LastWriteTime -lt (Get-Date).AddHours(-12)) {
            Remove-Item $f.FullName -ErrorAction SilentlyContinue; continue
        }
        # The read can fail right as hook.sh replaces the file - the next round should read again
        try { $lines = Read-StateLines $f.FullName } catch { $scanState.Failed = $true; continue }
        if ($lines.Count -eq 0) { continue }
        # Line 8 = "hidden" when the dot was closed via right-click. hook.sh writes only 7 lines,
        # so the dot comes back (with the same label) when the session becomes active again.
        if ($lines.Count -gt 7 -and $lines[7].Trim() -eq 'hidden') { continue }
        $cwd = if ($lines.Count -gt 1) { $lines[1] } else { '' }
        $label = if ($lines.Count -gt 2) { $lines[2].Trim() } else { '' }
        $hwnd = 0L
        if ($lines.Count -gt 3) { [long]::TryParse($lines[3].Trim(), [ref]$hwnd) | Out-Null }
        $termPid = 0
        if ($lines.Count -gt 4) { [int]::TryParse($lines[4].Trim(), [ref]$termPid) | Out-Null }
        $background = ($lines.Count -gt 5 -and $lines[5].Trim() -eq '1')
        $claudePid = 0
        if ($lines.Count -gt 6) { [int]::TryParse($lines[6].Trim(), [ref]$claudePid) | Out-Null }
        $list += [pscustomobject]@{ Id = $f.Name; State = $lines[0].Trim(); Cwd = $cwd; Label = $label; Hwnd = $hwnd; TermPid = $termPid; Background = $background; ClaudePid = $claudePid }
    }
    return $list
}

# Removes dots for sessions that no longer exist, e.g. after /resume, where the terminal's old
# session is parked without SessionEnd running. "claude agents --json" runs in the background every
# 30 seconds and writes to a file, so the tray app doesn't freeze while waiting.
# The list isn't treated as the truth for normal terminal sessions - a session waiting for the next
# message can be missing from it. See Test-SessionGone for the rules.
$claudeExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
if (-not (Test-Path $claudeExe)) { $claudeExe = 'claude' }
$agentsOut = Join-Path $env:USERPROFILE '.claude\trafficlight-agents.json'
$agentsErr = "$agentsOut.err"
$agentsCheck = @{ Proc = $null; LastStart = [datetime]::MinValue; Missing = @{} }

# Decides whether a session missing from "claude agents --json" is really gone:
# - background agent: yes, the list is reliable there
# - terminal session: only if the claude process has exited, if the process now runs another
#   session (/clear), or if the terminal switched to a background session after /resume (parkedJobId)
# - unknown claude process (older files): no, those are cleaned up after 12 hours instead
function Test-SessionGone([string]$id, $lines) {
    if ($lines.Count -gt 5 -and $lines[5].Trim() -eq '1') { return $true }
    $claudePid = 0
    if ($lines.Count -gt 6) { [int]::TryParse($lines[6].Trim(), [ref]$claudePid) | Out-Null }
    if ($claudePid -eq 0) { return $false }
    if (-not (Get-Process -Id $claudePid -ErrorAction SilentlyContinue)) { return $true }
    try { $reg = Get-Content -LiteralPath (Join-Path $sessionsDir "$claudePid.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if ($reg.sessionId -and $reg.sessionId -ne $id) { return $true }
    return [bool]$reg.parkedJobId
}

function Update-ActiveSessions {
    $c = $agentsCheck
    if ($c.Proc) {
        if (-not $c.Proc.HasExited) { return }
        $ok = ($c.Proc.ExitCode -eq 0)
        $c.Proc = $null
        if (-not $ok) { return }
        # ConvertFrom-Json in PowerShell 5.1 sends the whole array through the pipeline as one object,
        # so it has to be assigned first and then iterated - otherwise all ids become a single string
        try { $active = Get-Content -LiteralPath $agentsOut -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
        $activeIds = @{}
        foreach ($a in @($active)) {
            $sid = [string]$a.sessionId
            if ($sid -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { $activeIds[$sid] = $true }
        }
        # Safety check: if the list is empty but there are dots, something is probably wrong - touch nothing
        if ($activeIds.Count -eq 0) { return }

        foreach ($f in Get-ChildItem -Path $stateDir -File -ErrorAction SilentlyContinue) {
            if ($f.Extension -eq '.tmp') { continue }
            if ($activeIds.ContainsKey($f.Name)) { $c.Missing.Remove($f.Name); continue }
            # Keep recently written files - the session may not be registered yet
            if ($f.LastWriteTime -gt (Get-Date).AddSeconds(-15)) { continue }
            try { $lines = Read-StateLines $f.FullName } catch { continue }
            if (-not (Test-SessionGone $f.Name $lines)) { $c.Missing.Remove($f.Name); continue }
            $c.Missing[$f.Name] = 1 + [int]$c.Missing[$f.Name]
            # Require two misses in a row before removing the dot
            if ($c.Missing[$f.Name] -ge 2) {
                Remove-Item $f.FullName -ErrorAction SilentlyContinue
                $c.Missing.Remove($f.Name)
            }
        }
        return
    }
    if ((Get-Date) -lt $c.LastStart.AddSeconds(30)) { return }
    $c.LastStart = Get-Date
    try {
        $c.Proc = Start-Process -FilePath $claudeExe -ArgumentList 'agents', '--json' -NoNewWindow -PassThru `
            -RedirectStandardOutput $agentsOut -RedirectStandardError $agentsErr
        # Without reading Handle right away, ExitCode stays empty in PowerShell 5.1
        $null = $c.Proc.Handle
    } catch { $c.Proc = $null }
}

function Hide-Session([string]$id) {
    $path = Join-Path $stateDir $id
    try { $lines = Read-StateLines $path } catch { return }
    while ($lines.Count -lt 7) { $lines += '0' }
    $lines = @($lines[0..6]) + 'hidden'
    # Write atomically, just like hook.sh
    [System.IO.File]::WriteAllText("$path.tmp", (($lines -join "`n") + "`n"))
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}

# Stops a background agent. The conversation is kept, so "claude attach" can open it again.
function Stop-Agent([string]$id) {
    $claude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not (Test-Path $claude)) { $claude = 'claude' }
    Start-Process -FilePath $claude -ArgumentList 'stop', $id.Substring(0, 8) -WindowStyle Hidden
    Hide-Session $id
}

function Add-GlobalMenuItems($m) {
    $resetItem = $m.Items.Add('Reset (clear all sessions)')
    $resetItem.add_Click({ Get-ChildItem $stateDir -File | Remove-Item -ErrorAction SilentlyContinue })
    $exitItem = $m.Items.Add('Quit traffic light (all dots)')
    $exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
}

# Right-click menu for the gray dot (no sessions)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
Add-GlobalMenuItems $menu

# Right-click menu for a session's dot. The session id is stored in Tag so the click handlers know which one it is.
function New-SessionMenu([string]$id, [string]$label, [bool]$background) {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $hideItem = $m.Items.Add("Close dot $label")
    $hideItem.Tag = $id
    $hideItem.add_Click({ param($sender, $e) Hide-Session $sender.Tag })
    if ($background) {
        $stopItem = $m.Items.Add("Stop agent $label")
        $stopItem.Tag = $id
        $stopItem.add_Click({ param($sender, $e) Stop-Agent $sender.Tag })
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    Add-GlobalMenuItems $m
    return $m
}

# VS Code runs all windows in the same process, so hook.sh can only find "some" VS Code window.
# So pick the window whose title contains the workspace name (the title is "... - <name> - Visual Studio Code").
# The name comes from the VS Code extension's registry first; otherwise the folder names in cwd are
# tried from the deepest up, so that e.g. a worktree under my-project finds that window.
$windowsDir = Join-Path $env:USERPROFILE '.claude\trafficlight-windows'
function Find-WindowForCwd([System.IntPtr]$h, [string]$cwd, [int]$termPid) {
    $ownerPid = [uint32]0
    [Native.Win32]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
    $windows = New-Object System.Collections.ArrayList
    # EnumWindows goes in z-order, so the most recently used window comes first
    [Native.Win32]::EnumWindows({
        param($w, $l)
        $p = [uint32]0
        [Native.Win32]::GetWindowThreadProcessId($w, [ref]$p) | Out-Null
        if ($p -eq $ownerPid -and [Native.Win32]::IsWindowVisible($w)) {
            $sb = New-Object System.Text.StringBuilder 512
            [Native.Win32]::GetWindowText($w, $sb, 512) | Out-Null
            if ($sb.Length -gt 0) { [void]$windows.Add(@{ Handle = $w; Title = $sb.ToString() }) }
        }
        return $true
    }, [System.IntPtr]::Zero) | Out-Null
    if ($windows.Count -le 1) { return $h }

    $segments = @($cwd -split '[\\/]' | Where-Object { $_ -and $_ -notmatch ':$' })
    [array]::Reverse($segments)
    # Most reliable first: the VS Code extension has registered which window (workspace name) the terminal is in
    if ($termPid -ne 0) {
        foreach ($f in Get-ChildItem -Path $windowsDir -Filter *.json -ErrorAction SilentlyContinue) {
            try { $reg = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (@($reg.terminals) -contains $termPid -and $reg.name) { $segments = @($reg.name) + $segments; break }
        }
    }
    foreach ($seg in $segments) {
        foreach ($w in $windows) {
            if ($w.Title.Contains(" - $seg - ") -or $w.Title.StartsWith("$seg - ")) { return $w.Handle }
        }
    }
    return $h
}

# Asks the VS Code extension (vscode-extension/) to show the terminal tab whose shell has this pid.
# Every VS Code window watches the file, and only the window that owns the terminal reacts.
# For background agents the session id and label are sent too - the extension then opens
# (or reuses) a "claude attach" tab in the same window as the terminal.
$focusFile = Join-Path $env:USERPROFILE '.claude\trafficlight-focus'
function Request-TerminalFocus([int]$termPid, [string]$sessionId, [string]$label) {
    if ($termPid -eq 0) { return }
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $text = if ($sessionId) { "$termPid $stamp $sessionId $label" } else { "$termPid $stamp" }
    try { [System.IO.File]::WriteAllText($focusFile, $text) } catch {}
}

# When you run /resume in a terminal, Claude Code can start the conversation as a background session
# that the terminal then displays. The link isn't visible in the process tree, but the terminal's claude
# process gets "parkedJobId" in ~/.claude/sessions/<pid>.json. If exactly one such terminal has the same
# project folder as the background session, it is assumed to be the one showing the session.
$sessionsDir = Join-Path $env:USERPROFILE '.claude\sessions'
function Resolve-ResumedTerminal([int]$claudePid) {
    try { $bg = Get-Content -LiteralPath (Join-Path $sessionsDir "$claudePid.json") -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $candidates = @()
    foreach ($f in Get-ChildItem -Path $sessionsDir -Filter *.json -ErrorAction SilentlyContinue) {
        try { $s = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($s.kind -ne 'interactive' -or -not $s.parkedJobId -or $s.cwd -ne $bg.cwd) { continue }
        if (-not (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue)) { continue }
        $candidates += [int]$s.pid
    }
    if ($candidates.Count -ne 1) { return $null }
    # Same lookup that hook.sh does, but starting from the terminal's claude process
    $found = & (Join-Path $PSScriptRoot 'find-window.ps1') $candidates[0] | Select-Object -Last 1
    $parts = "$found" -split ' '
    if ($parts.Count -lt 2 -or [int]$parts[1] -eq 0) { return $null }
    return @{ Hwnd = [long]$parts[0]; TermPid = [int]$parts[1] }
}

# Brings up the session's window (terminal / VS Code) when the dot is clicked
function Show-SessionWindow([long]$hwnd, [string]$cwd, [int]$termPid, [string]$sessionId, [string]$label, [int]$claudePid) {
    # Background session with no known terminal (after /resume): show the terminal displaying it instead of a new tab
    if ($sessionId -and $termPid -eq 0 -and $claudePid -ne 0) {
        $r = Resolve-ResumedTerminal $claudePid
        if ($r) { $hwnd = $r.Hwnd; $termPid = $r.TermPid; $sessionId = '' }
    }
    Request-TerminalFocus $termPid $sessionId $label
    if ($hwnd -eq 0) { return }
    $h = [System.IntPtr]$hwnd
    if (-not [Native.Win32]::IsWindow($h)) { return }
    $h = Find-WindowForCwd $h $cwd $termPid
    if ([Native.Win32]::IsIconic($h)) { [Native.Win32]::ShowWindow($h, 9) | Out-Null }  # SW_RESTORE
    # A simulated Alt key press makes Windows allow changing the foreground window
    [Native.Win32]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)
    [Native.Win32]::keybd_event(0x12, 0, 2, [System.UIntPtr]::Zero)
    [Native.Win32]::SetForegroundWindow($h) | Out-Null
}

function New-Tray {
    $t = New-Object System.Windows.Forms.NotifyIcon
    $t.ContextMenuStrip = $menu
    return $t
}

# Gray dot shown only when there are no sessions (so the menu is always reachable)
$idleTray = New-Tray
$idleTray.Icon = Get-DotIcon 'off' ''
$idleTray.Text = 'Claude Code: ' + $labels['off']

# Session-id -> @{ Tray; Key }
$trays = @{}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$lastScan = @{ Signature = ''; At = [datetime]::MinValue }
$scanState = @{ Failed = $false }
$timer.add_Tick({
    Update-ActiveSessions

    # Only read the session files when something in the folder changed (name or modified time), plus
    # once a minute to clean up old sessions. Reading everything every second wastes CPU.
    $signature = ''
    try {
        $signature = (@([System.IO.Directory]::GetFiles($stateDir) | ForEach-Object {
            "$_|$([System.IO.File]::GetLastWriteTimeUtc($_).Ticks)" }) -join ';')
    } catch {}
    # Read again every round while a dot is waiting to be removed (see below)
    $pending = @($trays.Values | Where-Object { $_.MissingSince }).Count -gt 0
    if (-not $pending -and $signature -eq $lastScan.Signature -and (Get-Date) -lt $lastScan.At.AddMinutes(1)) { return }

    $scanState.Failed = $false
    $sessions = @(Get-Sessions)
    # Failed read: forget the signature so the folder is read again next second
    $lastScan.Signature = if ($scanState.Failed) { '' } else { $signature }
    $lastScan.At = Get-Date
    $seen = @{}

    foreach ($s in $sessions) {
        $seen[$s.Id] = $true
        $name = if ($s.Cwd) { Split-Path $s.Cwd -Leaf } else { '?' }
        # The label (e.g. T1) is set by hook.sh and also shows in Claude Code's status line
        $letter = if ($s.Label) { $s.Label } elseif ($name -and $name -ne '?') { $name.Substring(0, 1).ToUpper() } else { '?' }
        $label = if ($labels.ContainsKey($s.State)) { $labels[$s.State] } else { $s.State }

        if (-not $trays.ContainsKey($s.Id)) {
            $t = New-Tray
            $t.Visible = $true
            $entry = @{ Tray = $t; Key = ''; MenuKey = ''; Hwnd = 0L; Cwd = ''; TermPid = 0; AttachId = ''; Label = '' }
            # Left-click brings up the window, right-click shows the session's menu
            $t.add_MouseClick({
                param($sender, $e)
                if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
                foreach ($x in $trays.Values) { if ($x.Tray -eq $sender) { Show-SessionWindow $x.Hwnd $x.Cwd $x.TermPid $x.AttachId $x.Label $x.ClaudePid } }
            })
            $trays[$s.Id] = $entry
        }
        $entry = $trays[$s.Id]
        $entry.Hwnd = $s.Hwnd
        $entry.Cwd = $s.Cwd
        $entry.TermPid = $s.TermPid
        $entry.AttachId = if ($s.Background) { $s.Id } else { '' }
        $entry.ClaudePid = $s.ClaudePid
        $entry.Label = $letter
        $menuKey = "$letter|$($s.Background)"
        if ($entry.MenuKey -ne $menuKey) {
            $old = $entry.Tray.ContextMenuStrip
            $entry.Tray.ContextMenuStrip = New-SessionMenu $s.Id $letter $s.Background
            if ($old -and $old -ne $menu) { $old.Dispose() }
            $entry.MenuKey = $menuKey
        }
        $key = "$($s.State)|$letter"
        if ($entry.Key -ne $key) {
            $entry.Tray.Icon = Get-DotIcon $s.State $letter
            $entry.Key = $key
        }
        # Tooltip: max 127 characters in Windows
        $text = "$letter · $name - $label`n$($s.Cwd)"
        if ($text.Length -gt 127) { $text = $text.Substring(0, 124) + '...' }
        # Only set the text when it changed - every assignment is a call into Windows
        if ($entry.Tray.Text -ne $text) { $entry.Tray.Text = $text }
    }

    # Remove dots for sessions that have ended. A missing dot is kept for 3 seconds, so that
    # a file being replaced (or one that couldn't be read) doesn't make the dot disappear.
    foreach ($id in @($trays.Keys)) {
        if ($seen.ContainsKey($id)) { $trays[$id].MissingSince = $null; continue }
        if (-not $trays[$id].MissingSince) { $trays[$id].MissingSince = Get-Date }
        if ((Get-Date) -ge $trays[$id].MissingSince.AddSeconds(3)) {
            $trays[$id].Tray.Visible = $false
            $sessionMenu = $trays[$id].Tray.ContextMenuStrip
            $trays[$id].Tray.Dispose()
            if ($sessionMenu -and $sessionMenu -ne $menu) { $sessionMenu.Dispose() }
            $trays.Remove($id)
        }
    }

    $idleTray.Visible = ($trays.Count -eq 0)
})
$timer.Start()

[System.Windows.Forms.Application]::Run()

$timer.Stop()
foreach ($e in $trays.Values) { $e.Tray.Visible = $false; $e.Tray.Dispose() }
$idleTray.Visible = $false
$idleTray.Dispose()
$mutex.ReleaseMutex()
