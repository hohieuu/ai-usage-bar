#!/bin/bash
# Claude Code statusLine hook
# Saves per-session status JSON for SwiftBar to read
input=$(cat)
session_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)
echo "$input" > "/tmp/claude-status-${session_id}.json"
