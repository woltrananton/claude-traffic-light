#!/usr/bin/env bash
# Claude Code hook for the taskbar traffic light.
# Usage: hook.sh <yellow|red|green|start|end>   (hook JSON arrives on stdin)
# Writes one file per session in ~/.claude/trafficlight/ that the tray app and status line read:
#   line 1: status (yellow/red/green)
#   line 2: project folder (cwd)
#   line 3: label, e.g. T1 - the same label shows on the dot and in the status line
#   line 4: window handle (HWND) of the terminal/VS Code - clicking the dot brings up the window
#   line 5: pid of the VS Code terminal's shell (0 outside VS Code) - so the right terminal tab is shown
#   line 6: 1 for a background agent (agent view / --bg), shown with "claude attach" in its own tab
#   line 7: pid of the claude process - unchanged after /resume and /clear, which change the session id

state="$1"
input=$(cat)

dir="$HOME/.claude/trafficlight"
mkdir -p "$dir"

session=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n1)
[ -z "$session" ] && session="default"
file="$dir/$session"

# Ended sessions are kept in .ended/ for a day, so a background copy that starts right after the
# conversation it continues has ended can still take over its label (see below)
ended="$dir/.ended"

if [ "$state" = "end" ]; then
  if [ -f "$file" ]; then
    mkdir -p "$ended"
    mv -f "$file" "$ended/" 2>/dev/null || rm -f "$file"
  fi
  find "$ended" -type f -mtime +0 -delete 2>/dev/null
  exit 0
fi

# cwd in the JSON has doubled backslashes (C:\\Projects\\...) - turn them into single ones
cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\\\\/\\/g')

old_state=""
label=""
hwnd=""
termpid=""
bg=""
claudepid=""
if [ -f "$file" ]; then
  old_state=$(sed -n '1p' "$file")
  label=$(sed -n '3p' "$file")
  hwnd=$(sed -n '4p' "$file")
  termpid=$(sed -n '5p' "$file")
  bg=$(sed -n '6p' "$file")
  claudepid=$(sed -n '7p' "$file")
fi

# Look up the session's window once per session (takes under a second)
if [ -z "$hwnd" ] || [ -z "$termpid" ] || [ -z "$bg" ] || [ -z "$claudepid" ]; then
  winpid=$(cat /proc/$$/winpid 2>/dev/null)
  if [ -n "$winpid" ]; then
    found=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(dirname "$0")/find-window.ps1" "$winpid" 2>/dev/null | tr -d '\r' | tail -n1)
    read -r hwnd termpid bg claudepid <<< "$found"
  fi
  [ -z "$hwnd" ] && hwnd=0
  [ -z "$termpid" ] && termpid=0
  [ -z "$bg" ] && bg=0
  [ -z "$claudepid" ] && claudepid=0
fi

# "start" (new session / resume / clear): keep any existing status, otherwise green
if [ "$state" = "start" ]; then
  state="${old_state:-green}"
fi

# Notification also fires when Claude has just been waiting a while for the next message (idle_prompt,
# "Claude is waiting for your input"). That doesn't mean Claude needs you, so keep the
# current status - otherwise a finished (green) session turns red after about a minute.
if [ "$state" = "red" ]; then
  ntype=$(printf '%s' "$input" | sed -n 's/.*"notification_type" *: *"\([^"]*\)".*/\1/p' | head -n1)
  if [ "$ntype" = "idle_prompt" ] || printf '%s' "$input" | grep -q 'waiting for your input'; then
    state="${old_state:-green}"
  fi
fi

write_file() {
  # Write atomically so the tray app never reads a half-written file
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$state" "$cwd" "$label" "$hwnd" "$termpid" "$bg" "$claudepid" > "$file.tmp" || return
  # mv can fail ("Device or resource busy") if something else is reading the file right then - retry
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    mv -f "$file.tmp" "$file" 2>/dev/null && return
    sleep 0.05
  done
  rm -f "$file.tmp"
}

if [ -z "$label" ]; then
  # Lock so two sessions starting at the same time don't get the same number
  tries=0
  until mkdir "$dir/.lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 40 ] && break
    sleep 0.05
  done

  # /resume and /clear change the session id in the same claude process. Take over the old
  # session's label and delete its file, so there isn't an extra dot.
  if [ "$claudepid" != "0" ]; then
    for f in "$dir"/*; do
      [ -f "$f" ] && [ "$f" != "$file" ] || continue
      case "$f" in *.tmp) continue ;; esac
      if [ "$(sed -n '7p' "$f")" = "$claudepid" ]; then
        [ -z "$label" ] && label=$(sed -n '3p' "$f")
        rm -f "$f"
      fi
    done
  fi

  # Opening a terminal's own conversation from agent view (or /resume) continues it as a background
  # copy with a new session id. The terminal's claude process then gets "parkedJobId" = the copy's
  # short id in ~/.claude/sessions/<pid>.json. Take over the label of that terminal's dot.
  if [ -z "$label" ]; then
    parked=$(grep -l "\"parkedJobId\" *: *\"${session:0:8}\"" "$HOME/.claude/sessions/"*.json 2>/dev/null | head -n1)
    parkedpid="${parked##*/}"
    parkedpid="${parkedpid%.json}"
    if [ -n "$parkedpid" ]; then
      for f in "$dir"/* "$ended"/*; do
        [ -f "$f" ] && [ "$f" != "$file" ] || continue
        case "$f" in *.tmp) continue ;; esac
        if [ "$(sed -n '7p' "$f")" = "$parkedpid" ]; then
          [ -z "$label" ] && label=$(sed -n '3p' "$f")
          rm -f "$f"
        fi
      done
    fi
  fi

  if [ -z "$label" ]; then
    name="${cwd##*[\\/]}"
    letter="${name:0:1}"
    letter="${letter^^}"
    [ -z "$letter" ] && letter="?"

    used=$(for f in "$dir"/*; do [ -f "$f" ] && [ "$f" != "$file" ] && sed -n '3p' "$f"; done)
    n=1
    while printf '%s\n' "$used" | grep -qx "$letter$n"; do n=$((n + 1)); done
    label="$letter$n"
  fi

  # Write before releasing the lock so the next session sees the number
  write_file
  rmdir "$dir/.lock" 2>/dev/null
  exit 0
fi

write_file
exit 0
