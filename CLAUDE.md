# Project notes

Native macOS Winamp-style music player (SwiftUI + vDSP). Source under `Sources/Sonar`.

## Linear tracking

This project is tracked in Linear — team **AFT** (Afterglow), project **MacOS Music player**.

Convention: after a unit of work lands (a `git commit`), consider whether it's a
**feature** or a **notable bug fix**. If so, log it in Linear. Skip typos,
cosmetics, and trivial refactors.

How it's wired:
- A `PostToolUse` hook (`.claude/hooks/linear-reminder.sh`, registered in
  `.claude/settings.json`) fires after a `git commit` and injects a reminder.
- The reminder asks the assistant to check with the user, then — on approval —
  delegate to the **`linear-logger`** subagent (`.claude/agents/linear-logger.md`).
- `linear-logger` creates/updates the issue with the project set, an appropriate
  status (Done once committed **and pushed**), and a link to the commit.

Nothing is created without the user's confirmation.
