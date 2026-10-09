# Installs (or with -Uninstall, removes) the Claude Traffic Light for the current user:
#   1. adds the hooks and status line to ~/.claude/settings.json, pointing at this folder
#   2. creates a shortcut in the Startup folder so the tray app starts at login
#   3. starts the tray app
#   4. builds and installs the VS Code extension, if VS Code and Node.js are available
# Only the traffic light's own entries in settings.json are touched, and a backup is written first.
# Safe to run again, e.g. after moving the folder.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Uninstall] [-SkipExtension] [-NoStart]
param(
    [switch]$Uninstall,
    [switch]$SkipExtension,
    [switch]$NoStart,
    # Replace an existing status line that isn't the traffic light's
    [switch]$ReplaceStatusLine,
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$StartupFolder = [Environment]::GetFolderPath('Startup')
)
$ErrorActionPreference = 'Stop'
# In PowerShell 5.1 the extra Count property on arrays makes ConvertTo-Json write some arrays as
# {"value":[...],"Count":n}. Removing it for this script fixes that.
Remove-TypeData System.Array -ErrorAction SilentlyContinue

$root = $PSScriptRoot
$rootSlash = $root -replace '\\', '/'
$events = [ordered]@{
    SessionStart     = 'start'
    UserPromptSubmit = 'yellow'
    PreToolUse       = 'yellow'
    Notification     = 'red'
    Stop             = 'green'
    SessionEnd       = 'end'
}
# Recognizes the traffic light's hooks and status line wherever the folder was, so a reinstall
# after moving it replaces the old entries instead of adding new ones
$ourHook = 'hook\.sh"?\s+(start|yellow|red|green|end)\s*$'
$ourStatusLine = 'statusline\.sh"?\s*$'
$shortcutName = 'Claude Traffic Light.lnk'
$extensionId = 'woltrananton.claude-traffic-light-focus'

function Write-Step([string]$text) { Write-Host "-> $text" -ForegroundColor Cyan }

# Claude Code runs the hooks with bash, which has to be Git Bash. If "bash" on PATH is missing or
# is WSL's bash, use Git Bash's full path instead.
function Get-BashCommand {
    $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch '\\(System32|WindowsApps)\\') { return 'bash' }
    $candidates = @()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) { $candidates += Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe' }
    $candidates += Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return '"' + ($c -replace '\\', '/') + '"' }
    }
    throw 'Git Bash was not found. Install Git for Windows (https://git-scm.com/download/win) and run this again.'
}

# Pretty-prints compact JSON with two-space indentation. PowerShell 5.1's own ConvertTo-Json output
# is oddly indented and escapes < > & ' as < etc., which would make settings.json hard to read.
function Format-Json([string]$json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $unescape = @{}
    foreach ($hex in '003c', '003e', '0026', '0027') { $unescape[[string][char]92 + 'u' + $hex] = [string][char][Convert]::ToInt32($hex, 16) }
    for ($i = 0; $i -lt $json.Length; $i++) {
        $c = $json[$i]
        if ($inString) {
            if ($c -eq '\') {
                $seq = if ($i + 6 -le $json.Length) { $json.Substring($i, 6).ToLower() } else { '' }
                if ($unescape.ContainsKey($seq)) { [void]$sb.Append($unescape[$seq]); $i += 5 }
                else { [void]$sb.Append($c).Append($json[$i + 1]); $i++ }
                continue
            }
            [void]$sb.Append($c)
            if ($c -eq '"') { $inString = $false }
            continue
        }
        switch ($c) {
            '"' { $inString = $true; [void]$sb.Append($c) }
            { $_ -eq '{' -or $_ -eq '[' } {
                $close = if ($c -eq '{') { '}' } else { ']' }
                if ($i + 1 -lt $json.Length -and $json[$i + 1] -eq $close) { [void]$sb.Append("$c$close"); $i++; break }
                $indent++
                [void]$sb.Append($c).Append("`n").Append('  ' * $indent)
            }
            { $_ -eq '}' -or $_ -eq ']' } { $indent--; [void]$sb.Append("`n").Append('  ' * $indent).Append($c) }
            ',' { [void]$sb.Append(",`n").Append('  ' * $indent) }
            ':' { [void]$sb.Append(': ') }
            { $_ -eq ' ' -or $_ -eq "`t" -or $_ -eq "`r" -or $_ -eq "`n" } { }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return New-Object psobject }
    $text = [System.IO.File]::ReadAllText($SettingsPath)
    if (-not $text.Trim()) { return New-Object psobject }
    try { return $text | ConvertFrom-Json }
    catch { throw "Could not read $SettingsPath as JSON, so it was left unchanged: $($_.Exception.Message)" }
}

function Save-Settings($settings) {
    $dir = Split-Path $SettingsPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Test-Path -LiteralPath $SettingsPath) {
        Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak-trafficlight" -Force
    }
    $json = Format-Json ($settings | ConvertTo-Json -Depth 100 -Compress)
    # UTF-8 without BOM
    [System.IO.File]::WriteAllText($SettingsPath, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
}

function Set-Property($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# Removes the traffic light's hooks, then drops groups and events that end up empty.
# -KeepEmpty keeps an empty "hooks" so it stays in the same place in the file when hooks are added back.
function Remove-OurHooks($settings, [switch]$KeepEmpty) {
    if (-not $settings.PSObject.Properties['hooks']) { return }
    $hooks = $settings.hooks
    foreach ($event in @($hooks.PSObject.Properties.Name)) {
        $groups = @()
        foreach ($group in @($hooks.$event)) {
            if ($group.PSObject.Properties['hooks']) {
                $kept = @(@($group.hooks) | Where-Object { -not ($_.command -match $ourHook) })
                if ($kept.Count -eq 0) { continue }
                $group.hooks = $kept
            }
            $groups += $group
        }
        if ($groups.Count -eq 0) { $hooks.PSObject.Properties.Remove($event) }
        else { $hooks.$event = $groups }
    }
    if (-not $KeepEmpty -and @($hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
}

function Test-OurStatusLine($settings) {
    return ($settings.PSObject.Properties['statusLine'] -and "$($settings.statusLine.command)" -match $ourStatusLine)
}

function Install-Settings {
    Write-Step "Adding hooks and status line to $SettingsPath"
    $bash = Get-BashCommand
    $settings = Read-Settings
    Remove-OurHooks $settings -KeepEmpty
    if (-not $settings.PSObject.Properties['hooks']) { Set-Property $settings 'hooks' (New-Object psobject) }
    foreach ($event in $events.Keys) {
        $group = [ordered]@{}
        if ($event -eq 'PreToolUse') { $group.matcher = '*' }
        $group.hooks = @([ordered]@{ type = 'command'; command = "$bash `"$rootSlash/hook.sh`" $($events[$event])"; timeout = 10 })
        $existing = if ($settings.hooks.PSObject.Properties[$event]) { @($settings.hooks.$event) } else { @() }
        Set-Property $settings.hooks $event (@($existing) + [pscustomobject]$group)
    }

    $statusLine = [pscustomobject][ordered]@{ type = 'command'; command = "$bash `"$rootSlash/statusline.sh`""; refreshInterval = 2 }
    if (-not $settings.PSObject.Properties['statusLine'] -or (Test-OurStatusLine $settings) -or $ReplaceStatusLine) {
        Set-Property $settings 'statusLine' $statusLine
    } else {
        Write-Warning 'You already have a status line, so it was left as is. Run again with -ReplaceStatusLine to use the traffic light''s.'
    }
    Save-Settings $settings
}

function Uninstall-Settings {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return }
    Write-Step "Removing hooks and status line from $SettingsPath"
    $settings = Read-Settings
    Remove-OurHooks $settings
    if (Test-OurStatusLine $settings) { $settings.PSObject.Properties.Remove('statusLine') }
    Save-Settings $settings
}

# Shortcuts in the Startup folder that start this app, whatever they are called
function Get-OurShortcuts {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($f in Get-ChildItem -LiteralPath $StartupFolder -Filter *.lnk -ErrorAction SilentlyContinue) {
        if ($shell.CreateShortcut($f.FullName).Arguments -match 'start-trafficlight\.vbs') { $f }
    }
}

function Install-Shortcut {
    Write-Step 'Creating Startup shortcut'
    Get-OurShortcuts | Remove-Item -Force
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $StartupFolder $shortcutName))
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '"' + (Join-Path $root 'start-trafficlight.vbs') + '"'
    $shortcut.WorkingDirectory = $root
    $shortcut.Save()
}

function Get-TrayProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match 'trafficlight\.ps1' }
}

function Install-Extension {
    if ($SkipExtension) { return }
    $code = Get-Command code -ErrorAction SilentlyContinue
    $npx = Get-Command npx -ErrorAction SilentlyContinue
    if (-not $code) { Write-Host '   VS Code (code) not found, skipping the extension.'; return }
    if (-not $npx) { Write-Warning 'Node.js (npx) not found, so the VS Code extension was not installed. Install Node.js and run this again.'; return }
    Write-Step 'Building and installing the VS Code extension'
    $vsix = Join-Path $root 'vscode-extension\claude-traffic-light-focus.vsix'
    Push-Location (Join-Path $root 'vscode-extension')
    try {
        & npx --yes @vscode/vsce package --skip-license -o $vsix | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Building the extension failed.' }
    } finally { Pop-Location }
    & code --install-extension $vsix --force | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Installing the extension failed.' }
    Write-Host '   Reload open VS Code windows once (Ctrl+Shift+P -> Developer: Reload Window).'
}

if ($Uninstall) {
    $tray = @(Get-TrayProcesses)
    if ($tray.Count) { Write-Step 'Stopping the tray app'; $tray | ForEach-Object { Stop-Process -Id $_.ProcessId -Force } }
    Uninstall-Settings
    if (@(Get-OurShortcuts).Count) { Write-Step 'Removing Startup shortcut'; Get-OurShortcuts | Remove-Item -Force }
    if (-not $SkipExtension -and (Get-Command code -ErrorAction SilentlyContinue)) {
        if (@(& code --list-extensions) -contains $extensionId) {
            Write-Step 'Uninstalling the VS Code extension'
            & code --uninstall-extension $extensionId | Out-Null
        }
    }
    Write-Step 'Removing session files'
    $claudeDir = Join-Path $env:USERPROFILE '.claude'
    foreach ($name in 'trafficlight', 'trafficlight-windows', 'trafficlight-focus', 'trafficlight-agents.json', 'trafficlight-agents.json.err') {
        Remove-Item -LiteralPath (Join-Path $claudeDir $name) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "`nUninstalled. You can now delete this folder." -ForegroundColor Green
    return
}

Install-Settings
Install-Shortcut
if (-not $NoStart) {
    Write-Step 'Starting the tray app'
    & (Join-Path $env:SystemRoot 'System32\wscript.exe') (Join-Path $root 'start-trafficlight.vbs')
}
Install-Extension
Write-Host "`nInstalled. If a Claude Code session that was already running gets no dot, restart it." -ForegroundColor Green
