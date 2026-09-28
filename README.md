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

## Commands & Usage

### 1. `sweep list`
Lists all installed applications in `/Applications` and `~/Applications` with bundle identifiers and sizes.

```bash
swift run sweep list
swift run sweep list --json
```

### 2. `sweep scan <app>`
Discovers the application bundle and all associated leftover files, caches, preferences, and launch agents without touching anything.

`<app>` accepts an app name (e.g. `"Slack"`), a bundle ID (`"com.tinyspeck.slackmacgap"`), or a direct path (`"/Applications/Slack.app"`).

```bash
swift run sweep scan "Google Chrome"
swift run sweep scan com.jetbrains.intellij --json
```

### 3. `sweep remove <app>`
Runs a scan, provides an interactive checklist to review and toggle items, halts running processes gracefully, unloads launch agents, and moves files to the Trash.

```bash
# Safe interactive removal
swift run sweep remove "Slack"

# Safe trial run (simulates removal and shows all target file paths without touching disk)
swift run sweep remove "Slack" --dry-run --yes

# Non-interactive removal
swift run sweep remove "Slack" --yes

# Include low-confidence (vendor-level) matches
swift run sweep remove "Slack" --include-low-confidence

# Permanent deletion (bypasses Trash - use with caution)
swift run sweep remove "Slack" --permanent
```

### 4. `sweep doctor`
Verifies Full Disk Access (FDA), macOS compatibility, Trash permissions, and SIP protection, with actionable fix instructions.

```bash
swift run sweep doctor
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
