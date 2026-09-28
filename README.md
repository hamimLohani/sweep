# sweep 🧹

> A professional, safe, and transparent macOS application uninstaller written in Swift.

Dragging an application to the macOS Trash leaves behind orphaned caches, preferences, containers, launch agents, and privileged helper tools. `sweep` locates all associated application components using data-driven rules, shows you exactly what will be removed, and moves them to the Trash safely with full audit logging.

---

## Key Features

- **🛡️ Safe by Default**: Moves files to the native macOS Trash via `FileManager.default.trashItem`, preserving native Finder *"Put Back"* recovery. Permanent deletion requires explicit `--permanent`.
- **👁️ 100% Transparent**: Shows the exact file path and category of every candidate before taking action.
- **⚡ Fast & Native**: Built in modern Swift with Foundation and POSIX APIs. Universal binary supporting Apple Silicon (`arm64`) and Intel (`x86_64`).
- **⚙️ Data-Driven Rules**: All library and cache search paths are declared in `search_rules.json` rather than hardcoded logic.
- **🎯 Tiered Confidence Scoring**: Distinguishes between **High** (exact bundle ID & package receipts), **Medium** (exact app name), and **Low** (vendor tokens) confidence matches to prevent false positives.
- **🔒 Strict System Invariants**: System Integrity Protection (SIP) paths, Apple system apps (`com.apple.*`), and credential stores (`~/Library/Keychains`) are blocked by defense-in-depth security guards.
- **📜 Audit Trail**: Records every removal transaction with original paths, trash destinations, and timestamps in `~/.config/sweep/history.json`.

---

## Installation & Build

### Homebrew (Recommended)

You can install `sweep` directly via Homebrew using the custom tap:

```bash
brew tap hamimlohani/tap
brew install sweep
```

To update to future versions:
```bash
brew upgrade sweep
```

### Requirements
- macOS 13.0 (Ventura) or later
- Swift 5.9+ / Xcode Command Line Tools

### Building from Source

```bash
git clone https://github.com/your-username/mac_uninstaller.git
cd mac_uninstaller

# Build debug binary
swift build

# Build optimized Universal Binary (arm64 + x86_64)
swift build -c release --arch arm64 --arch x86_64

# Binary will be available at:
# .build/apple/Products/Release/sweep
```

To run tests:
```bash
swift run sweep-tests
```

---

---

## Commands & Usage Reference

Once installed via Homebrew, run `sweep` directly. (If building from source without installing, you can substitute `swift run sweep` for `sweep`).

### Quick Command Summary

| Command | Description | Example |
| :--- | :--- | :--- |
| `sweep list` | List installed applications and sizes | `sweep list` |
| `sweep scan <app>` | Scan app and leftovers without deleting anything | `sweep scan "Slack"` |
| `sweep remove <app>` | Scan, review checklist, and move items to Trash | `sweep remove "Slack"` |
| `sweep doctor` | Check permissions, FDA, SIP, and compatibility | `sweep doctor` |
| `sweep --help` | Show command-line help and usage | `sweep --help` |
| `sweep --version` | Display installed version | `sweep --version` |
| `man sweep` | View the complete UNIX manual page | `man sweep` |

---

### 1. `sweep list`
Discovers and lists installed applications in `/Applications` and `~/Applications`, displaying their application name, reverse-DNS bundle identifier, and disk size.

```bash
# Formatted aligned table output
sweep list

# Machine-readable JSON output (ideal for scripts and pipelines)
sweep list --json
```

**Options:**
- `--json` : Output installed application list in structured JSON.

---

### 2. `sweep scan <app>`
Performs a deep, read-only inspection of an application and all associated leftover files, caches, sandboxed containers, saved states, preferences, and launch agents. **Deletes nothing.**

`<app>` accepts any of the following formats:
- **Application Name**: `sweep scan "Google Chrome"` or `sweep scan Slack`
- **Bundle Identifier**: `sweep scan com.google.Chrome`
- **Application Path**: `sweep scan /Applications/Google\ Chrome.app`

```bash
# Standard categorized scan with human-readable sizes and match reasons
sweep scan "Google Chrome"

# Scan by bundle identifier with JSON output
sweep scan com.jetbrains.intellij --json
```

**Options:**
- `--json` : Output full `ScanResult` schema in structured JSON.

---

### 3. `sweep remove <app>`
The complete uninstallation workflow:
1. Resolves the application bundle.
2. Checks if the app is currently running (prompts and gracefully terminates if running).
3. Discovers all associated leftovers across user and system domains.
4. Presents an interactive checklist to review/deselect items.
5. Unloads any active LaunchAgents or LaunchDaemons (`launchctl bootout`).
6. Re-verifies safety invariants and moves items to the macOS Trash (`FileManager.trashItem`).
7. Logs an atomic removal transaction to `~/.config/sweep/history.json`.

```bash
# 1. Interactive Review (Recommended for standard uninstalls)
# Prompts you to review and deselect items before trashing
sweep remove "Slack"

# 2. Safe Trial Run (Dry Run)
# Shows every file path that would be touched without modifying or deleting anything
sweep remove "Slack" --dry-run --yes

# 3. Automated / Non-Interactive Removal
# Skips prompts and moves High & Medium confidence items to Trash
sweep remove "Slack" --yes
sweep remove "Slack" -y

# 4. Deep Clean (Include Low-Confidence / Vendor Items)
# Flags shared vendor folders (e.g. ~/Library/Application Support/Google) for removal
sweep remove "Google Chrome" --include-low-confidence

# 5. Permanent Deletion (Caution)
# Bypasses the macOS Trash and directly removes files from disk (cannot be Put Back)
sweep remove "Slack" --permanent

# 6. Automated JSON Pipeline
# Runs removal and outputs the final transaction record as JSON
sweep remove "Slack" --yes --json
```

**Options for `remove`:**
- `--dry-run` : Simulate removal without moving or deleting any files. Displays all target file paths with `[WOULD REMOVE]`.
- `-y`, `--yes` : Skip interactive confirmation and proceed with High & Medium confidence items.
- `--permanent` : Permanently delete files (`rm`) instead of moving them to `~/.Trash`.
- `--include-low-confidence` : Include low-confidence (vendor-level) matches in candidate list.
- `--json` : Output the final `RemovalRecord` transaction as JSON.

#### Interactive Checklist Controls

When running `sweep remove` interactively, a checklist is displayed:

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

- `[Enter]` : Confirm current selection and proceed with removal.
- `[1-N]` : Type an item number to toggle its checkbox on/off.
- `[a]` : Select all discovered items.
- `[n]` : Deselect all items.
- `[q]` : Abort operation safely (no files touched).

---

### 4. `sweep doctor`
Diagnoses your system environment and permissions to ensure `sweep` can operate safely and thoroughly.

```bash
sweep doctor
```

**Checks performed:**
- **macOS Version Compatibility**: Verifies macOS 13.0+ (Ventura) for APFS and modern `launchctl` support.
- **Full Disk Access (FDA)**: Verifies whether the terminal has FDA to scan privacy-guarded Library domains (`~/Library/Safari`, `~/Library/Mail`, sandboxed cookies). Provides exact instructions to enable it if missing.
- **macOS Trash Directory**: Checks that `~/.Trash` is writable for safe file removals.
- **System Integrity Protection (SIP)**: Verifies that macOS core system protection is active.
- **Audit History Store**: Checks write permissions for `~/.config/sweep/history.json`.

---

### 5. Manual Page (`man sweep`)
A full UNIX manual page is installed in Section 1:

```bash
man sweep
```

---

### Common Workflows & Recipes

#### Safe Verification Before Uninstalling
```bash
# Step 1: Check what files exist
sweep scan "Spotify"

# Step 2: Simulate what will happen
sweep remove "Spotify" --dry-run --yes

# Step 3: Perform actual removal
sweep remove "Spotify"
```

#### Uninstalling by Bundle Identifier (Headless or Scripted)
```bash
sweep remove com.tinyspeck.slackmacgap --yes
```

#### Auditing Removal History
All removals are logged in JSON format. You can inspect your past uninstallations using `cat` or `jq`:
```bash
cat ~/.config/sweep/history.json
# Or pretty-print with jq:
jq . ~/.config/sweep/history.json
```

---

## Safety Invariants & macOS Protections

1. **Strict Denylist**:
   `sweep` rejects any operations involving:
   - Root & System Volumes: `/`, `/System`, `/usr`, `/bin`, `/sbin`, `/private/etc`
   - System Integrity directories: `/Library/Apple`, `/Library/SystemExtensions`
   - User Credential & Identity Stores: `~/Library/Keychains`, `~/Library/AuthenticationServices`, `~/Library/IdentityServices`, `~/Library/Accounts`
2. **Apple System Application Shield**:
   Any bundle identifier starting with `com.apple.` or located inside `/System/Applications` cannot be scanned or removed.
3. **Symlink Escape Guard**:
   Every path is canonicalized with POSIX symlink resolution (`resolvingSymlinksInPath()`). Any symlink attempting to escape into system directories or outside allowed user/application roots is rejected.
4. **Defense-in-Depth**:
   Safety checks run twice: once during scanning, and once again immediately before moving each individual file into the Trash.
5. **Length Guards**:
   Short application names (e.g., apps named `"Go"` or `"R"`) are restricted from loose folder name matching to prevent deleting shared or unrelated resources.

---

## Exit Codes

`sweep` conforms to standard UNIX CLI exit codes:

| Code | Meaning | Description |
| :---: | :--- | :--- |
| `0` | **Success** | Command completed successfully. |
| `1` | **General Error** | Unhandled runtime error or process execution failure. |
| `2` | **Usage Error** | Invalid flags, missing required arguments, or invalid path. |
| `3` | **Permission Error** | Operation blocked by permissions, SIP, or Full Disk Access required. |
| `4` | **App Not Found** | The specified target application was not found. |

---

## Architecture & Extension Points

The codebase is split into:
- **`SweepCore`**: A clean, testable Swift framework containing models, resolvers, scanners, safety guards, and execution engines.
- **`sweep`**: The command-line interface executable using `swift-argument-parser` and ANSI UI helpers.

### Future Extension Points:
- **`sweep restore`**: The audit manifest format in `~/.config/sweep/history.json` maps each `originalPath` to its `trashPath`, enabling a future restore command to put files back.
- **`sweep orphans`**: The `LeftoverScanner` engine can perform an inverted scan across `~/Library/Containers` and `~/Library/Application Support` to identify leftover folders whose parent application is no longer installed.

---

## Known Limitations

- **App Store & System Sandboxing**: Certain folders inside `~/Library` require **Full Disk Access** granted to your Terminal app (run `sweep doctor` to verify).
- **Keychain Items**: Sandboxed keychain entries are managed directly by Apple's `Security.framework`. Because raw deletion of keychain databases would corrupt the user's login keychain, `sweep` enforces a zero-touch policy on keychain files.
- **Kernel Extensions**: macOS Big Sur+ replaces kernel extensions (`kext`) with System Extensions managed through macOS System Settings. `sweep` does not unload system extensions requiring root MDM / SIP modifications.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
