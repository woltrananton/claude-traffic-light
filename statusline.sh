#!/usr/bin/env bash
# Status line for Claude Code: shows the same label and color as the session's dot in the taskbar.
# Never creates the session file itself - the hooks do that - so ended sessions don't come back.

input=$(cat)
session=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -n1)
file="$HOME/.claude/trafficlight/$session"

if [ -z "$session" ] || [ ! -f "$file" ]; then
  printf '\033[90m●\033[0m traffic light: waiting for first message'
  exit 0
fi

state=$(sed -n '1p' "$file")
cwd=$(sed -n '2p' "$file")
label=$(sed -n '3p' "$file")
name="${cwd##*[\\/]}"

case "$state" in
  red)    color='31'; text='Needs you' ;;
  yellow) color='33'; text='Working' ;;
  green)  color='32'; text='Done' ;;
  *)      color='90'; text="$state" ;;
esac

printf '\033[%sm●\033[0m \033[1m%s\033[0m · %s · %s' "$color" "$label" "$name" "$text"
