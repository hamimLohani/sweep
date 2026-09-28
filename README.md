# sweep 🧹

[![macOS](https://img.shields.io/badge/macOS-13.0%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Homebrew](https://img.shields.io/badge/Homebrew-hamimlohani%2Ftap-blue?logo=homebrew)](https://github.com/hamimlohani/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **The clean, safe, and transparent macOS application uninstaller.**  
> Completely remove Mac apps and all their hidden leftovers, caches, preferences, and background agents — with zero leftover junk.

---

## Why Sweep?

Dragging an app to the Trash on macOS only deletes the `.app` bundle. Behind the scenes, gigabytes of cached files, sandbox containers, preferences, and launch agents stay behind indefinitely in `~/Library`.

`sweep` automatically finds every leftover file, shows you exactly what it found, and moves everything to the **native macOS Trash** — so you're always in complete control and can restore items with Finder's native **"Put Back"** anytime.

```text
$ sweep scan "Google Chrome"

Application: Google Chrome
Bundle ID:   com.google.Chrome
Version:     152.0.7977.64
App Path:    /Applications/Google Chrome.app
App Size:    1.47 GB
─────────────────────────────────────────────────────────────────
Detected Leftover Files (14 items):

📂 Application Support (1 items, 795.1 MB)
  [LOW]  ~/Library/Application Support/Google (795.1 MB)
📂 Darwin User Cache Directory (9 items, 10.9 MB)
  [HIGH] /private/var/folders/.../com.google.Chrome (1.6 MB)
📂 Preferences (2 items, 991 bytes)
  [HIGH] ~/Library/Preferences/com.google.Chrome.plist (949 bytes)
📂 WebKit Data (1 items, 3 MB)
  [HIGH] ~/Library/WebKit/com.google.Chrome (3 MB)
─────────────────────────────────────────────────────────────────
Total Disk Space: 2.31 GB
```

---

## Quick Install

Install in one command via [Homebrew](https://brew.sh):

```bash
brew tap hamimlohani/tap
brew install sweep
```

To update `sweep` in the future:
```bash
brew upgrade sweep
```

---

## Quickstart

### 1. Remove an App (Interactive & Safe)
```bash
sweep remove "Slack"
```
Sweep checks if the app is running (offering to quit it), unloads background launch agents, shows an interactive checklist where you can toggle items, and moves everything to your Trash.

### 2. Preview Before Deleting (Safe Scan)
```bash
sweep scan "Spotify"
```
Inspect all files and caches created by an app without touching or deleting anything.

### 3. See Every File With a Dry Run
```bash
sweep remove "Spotify" --dry-run --yes
```
Simulates the entire removal process and prints out the exact path of every file that would be removed.

### 4. List Installed Apps and Disk Space
```bash
sweep list
```
View all applications installed on your Mac, their bundle IDs, and how much disk space they occupy.

### 5. Check System Health & Permissions
```bash
sweep doctor
```
Verifies that `sweep` has all necessary permissions (like Full Disk Access and Trash access) to scan and clean thoroughly.

---

## Interactive Removal Checklist

When you run `sweep remove`, you get a clear, interactive menu before anything happens:

```text
Review items to remove:
──────────────────────────────────────────────────────────────────────
 1. [✓] [HIGH] ~/Library/Preferences/com.example.app.plist (4.2 KB)
 2. [✓] [HIGH] ~/Library/Containers/com.example.app (12.4 MB)
 3. [✓] [MED]  ~/Library/Application Support/ExampleApp (45.1 MB)
 4. [ ] [LOW]  ~/Library/Application Support/ExampleVendor (5.2 MB)
──────────────────────────────────────────────────────────────────────
Selected: 3/4 items (61.7 MB)

Commands: [Enter] Proceed | [1-4] Toggle item | [a] Select all | [n] Select none | [q] Cancel
Enter choice:
```

- **`[Enter]`**: Move all selected items to Trash.
- **`[1-N]`**: Toggle any file on or off.
- **`[a]`**: Select all items.
- **`[n]`**: Deselect all items.
- **`[q]`**: Abort safely without touching any files.

---

## Command Reference

| Command | What it does | Example |
| :--- | :--- | :--- |
| `sweep list` | Shows all installed apps and disk sizes | `sweep list` |
| `sweep scan <app>` | Discovers all leftovers (deletes nothing) | `sweep scan "Discord"` |
| `sweep remove <app>` | Interactive uninstaller with checklist | `sweep remove "Discord"` |
| `sweep doctor` | Diagnoses permissions and system compatibility | `sweep doctor` |
| `sweep --help` | Shows help instructions | `sweep --help` |
| `sweep --version` | Displays installed version | `sweep --version` |
| `man sweep` | Opens the full manual page | `man sweep` |

### Useful Flags for `sweep remove`

- **`--dry-run`**: Simulate the removal without modifying or trashing any files.
- **`-y`, `--yes`**: Skip confirmation prompts (ideal for scripts and fast uninstalls).
- **`--include-low-confidence`**: Also include shared vendor folders (e.g. `~/Library/Application Support/Google`).
- **`--permanent`**: Permanently deletes files immediately instead of moving them to Trash (use with caution).
- **`--json`**: Output the removal transaction record as clean JSON.

---

## Safety Guarantees

Your system's safety and data integrity are the #1 priority:

- **Move to Trash by Default**: Files go to `~/.Trash`, meaning you can open Trash and click **"Put Back"** at any time.
- **Zero-Touch on Passwords & Keychains**: `sweep` strictly blocks all keychain directories (`~/Library/Keychains`) and authentication services. It will never touch your logins, credentials, or passkeys.
- **Apple Protected Apps Shield**: `sweep` refuses to touch macOS system applications (`com.apple.*`) or protected system directories (`/System`, `/usr`, `/bin`, `/sbin`).
- **Anti-Traversal Protection**: All paths are resolved before action; symlinks attempting to trick the tool into escaping to system files are immediately rejected.
- **Audit History**: Every uninstall logs an atomic receipt to `~/.config/sweep/history.json` with original paths and trash locations.

---

## Frequently Asked Questions (FAQ)

### Can I restore an app I removed?
**Yes!** Because `sweep` moves items to the macOS Trash rather than destroying them, you can simply open your **Trash**, right-click any item, and select **"Put Back"**.

### Why does `sweep doctor` suggest Full Disk Access?
macOS protects sensitive user data (like Mail and Safari caches) under Transparency, Consent, and Control (TCC). Giving your Terminal app Full Disk Access (*System Settings → Privacy & Security → Full Disk Access*) allows `sweep` to find deep sandbox containers without causing permission popups.

### Can I pass an app's bundle ID instead of its name?
Yes! `sweep scan` and `sweep remove` accept:
- Application name: `sweep remove "Visual Studio Code"`
- Bundle ID: `sweep remove com.microsoft.VSCode`
- Direct path: `sweep remove /Applications/Visual\ Studio\ Code.app`

---

## Contributing & Building from Source

If you want to contribute to `sweep` or build it locally:

```bash
git clone https://github.com/hamimLohani/sweep.git
cd sweep

# Build debug binary
swift build

# Run unit tests (runs in isolated temporary sandboxes)
swift run sweep-tests

# Build universal release binary (arm64 + x86_64)
swift build -c release --arch arm64 --arch x86_64
```

---

## Author

Created with care by **Md. Inzamamul Lohani** ([@hamimLohani](https://github.com/hamimLohani)).  
Feedback, bug reports, and pull requests are warmly welcomed!

---

## License

Released under the [MIT License](LICENSE) © 2026 Md. Inzamamul Lohani.
