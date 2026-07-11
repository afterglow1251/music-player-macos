#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). Fires after every Bash call, but only
# nudges when the command was a `git commit` — i.e. a unit of work just landed.
# It doesn't create anything itself; it injects a reminder so the main agent
# decides whether the change is worth tracking and, if so, delegates to the
# linear-logger subagent.
input=$(cat)
if printf '%s' "$input" | grep -qE 'git[[:space:]]+commit'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[Linear check] A git commit just landed. Decide whether this change is a feature or a notable bug fix worth tracking (SKIP typos, cosmetics, and trivial refactors). If it is worth tracking: (1) ask the user whether to log it in Linear, and (2) only on a yes, delegate to the linear-logger subagent to create or update the issue. Do not create anything without the user's confirmation."}}
JSON
fi
exit 0
