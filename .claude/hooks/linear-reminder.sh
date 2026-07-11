#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). Fires after every Bash call, but only
# nudges when the command was a `git commit` — i.e. a unit of work just landed.
# It doesn't create anything itself; it injects a reminder so the main agent
# hands the change to the linear-logger subagent, which autonomously decides
# whether it's worth tracking and logs it — no user prompt.
input=$(cat)
if printf '%s' "$input" | grep -qE 'git[[:space:]]+commit'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[Linear check] A git commit just landed. Delegate to the linear-logger subagent (pass the commit hash + a one-line summary of what changed). It decides on its own whether the change is worth tracking — SKIPPING typos, cosmetics, and trivial refactors — and, if so, creates/closes the Linear issue and links the commit. Do NOT ask the user first; this is autonomous. Just relay back what it logged (or that it skipped)."}}
JSON
fi
exit 0
