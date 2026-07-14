Sonar — a native macOS Winamp-style music player. **Beta build.**

## Install

1. Download **`Sonar-<version>.zip`** below and unzip it.
2. Drag **`Sonar.app`** into your **Applications** folder.

## First launch (important)

This is a free beta, so it isn't notarized by Apple. macOS will refuse to open
it on a plain double-click the first time. This is expected — you only do this
once.

**Fastest fix (Terminal):**

```
xattr -cr /Applications/Sonar.app
```

This clears the quarantine flag Gatekeeper adds to downloaded apps. After
running it, Sonar opens normally on double-click — no dialogs.

**Without Terminal:**

On recent macOS (Sequoia/Tahoe), double-clicking shows a dialog that says
Apple couldn't verify the app, with only **Done** / **Move to Bin** — no
"Open Anyway" button here.

1. Click **Done** (not Move to Bin).
2. Go to **System Settings → Privacy & Security**, scroll down to the
   Security section — you'll see **"Sonar" was blocked...** with an
   **Open Anyway** button.
3. Click **Open Anyway**, confirm with your password/Touch ID.
4. Open Sonar again — a second dialog appears, this time with an **Open**
   button.

After that first time, Sonar opens normally like any other app.

## Requirements

- macOS 14 (Sonoma) or later.
