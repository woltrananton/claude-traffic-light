# Finds the window (terminal / VS Code) that a Claude Code session runs in.
# Walks up the process tree from the hook process until a process with a main window is found.
# Usage: find-window.ps1 <windows-pid>
# Prints "<window-handle> <terminal-pid> <background> <claude-pid>", 0 where nothing is found.
# Terminal pid is the shell VS Code started the terminal with - the VS Code extension uses it
# to show the right terminal tab when several Claude sessions run in the same window.
# Background is 1 for background agents (agent view / --bg). They run under Claude Code's daemon,
# so the search continues from the terminal that started the daemon (--spawned-by).
# Claude pid is the process running the session. It stays the same after /resume and /clear,
# even though the session id changes, so hook.sh can let the new session take over the old dot.
param([int]$StartPid)

$all = @{}
foreach ($p in Get-CimInstance Win32_Process) { $all[[int]$p.ProcessId] = $p }

$shellPid = 0
$background = 0
$claudePid = 0
$id = $StartPid
for ($i = 0; $i -lt 30 -and $all.ContainsKey($id); $i++) {
    # explorer.exe means we've gone past the terminal - give up
    if ($all[$id].Name -eq 'explorer.exe') { break }
    $cmd = [string]$all[$id].CommandLine
    if ($all[$id].Name -eq 'claude.exe' -and $cmd -match 'daemon run' -and $cmd -match 'spawned-by.*?pid\\?"\s*:\s*(\d+)') {
        $background = 1
        $id = [int]$Matches[1]
        continue
    }
    if ($claudePid -eq 0 -and $all[$id].Name -eq 'claude.exe') { $claudePid = $id }
    $parent = [int]$all[$id].ParentProcessId
    if ($shellPid -eq 0 -and $all.ContainsKey($parent) -and $all[$parent].Name -eq 'Code.exe' -and $all[$id].Name -ne 'Code.exe') {
        $shellPid = $id
    }
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne [System.IntPtr]::Zero) {
        "$($proc.MainWindowHandle.ToInt64()) $shellPid $background $claudePid"
        exit
    }
    $id = $parent
}
"0 $shellPid $background $claudePid"
