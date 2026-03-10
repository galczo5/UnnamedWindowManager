# Plan: 11_custom_commands — User-Defined Keyboard Shortcuts That Run Shell Commands

## Checklist

- [x] Add `CommandConfig` struct and `commands` field to `ConfigData`
- [x] Add `mergedWithDefaults` and `missingKeys` support for commands
- [x] Add `commands` accessors to `Config`
- [x] Add `commands` section to `ConfigLoader.format()`
- [x] Create `CommandService` to run shell commands
- [x] Add `enter`/`return` keyCode support to `KeybindingService.parse()`
- [x] Add duplicate shortcut detection to `KeybindingService.start()`
- [x] Register custom command bindings in `KeybindingService.start()`
- [x] Wire `CommandService` restart on config reload (already wired — `restart()` called on reload)

---

## Context / Problem

The app has built-in global shortcuts for window management (snap, focus, etc.) but no way to launch apps or run arbitrary commands via keyboard. Users want to bind custom shortcuts to shell commands in the config file (e.g. cmd+Enter to launch Alacritty). Shortcuts must be unique across both built-in and custom bindings — duplicates should post a notification and disable all shortcuts.

---

## Behaviour spec

- Config section `commands` holds a list of `{shortcut, run}` pairs
- Default: one entry — `cmd+enter` runs `open -n -a Alacritty`
- On `start()`, all shortcut strings (built-in + custom) are checked for duplicates
- Duplicates are compared after normalizing (lowercase, sorted modifiers, same key)
- If any duplicate is found: post a notification naming the conflicting shortcut, register zero bindings, log the conflict
- Empty `shortcut` or `run` strings skip that entry silently
- Shell commands execute via `/bin/sh -c "<run>"` asynchronously on a background queue
- `enter`/`return` are recognized as special keys (keyCode 36) in `parse()`

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add `CommandConfig` struct, `commands` field to `ConfigSection`, update defaults/merge/missingKeys |
| `UnnamedWindowManager/Config.swift` | Modify — add `commands` accessor |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add `commands` section to `format()` |
| `UnnamedWindowManager/Services/CommandService.swift` | **New file** — runs shell commands via `/bin/sh -c` |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — add duplicate detection, register command bindings, support `enter`/`return` keyCode |

---

## Implementation Steps

### 1. Add `CommandConfig` to `ConfigData`

Add a struct for a single command entry and a `commands` field on `ConfigSection`:

```swift
struct CommandConfig: Codable {
    var shortcut: String?
    var run: String?
}
```

Add `var commands: [CommandConfig]?` to `ConfigSection`.

Update `defaults` to include one default command:

```swift
commands: [CommandConfig(shortcut: "cmd+enter", run: "open -n -a Alacritty")]
```

Update `mergedWithDefaults()` — commands are not individually merged; if the user provides the `commands` array, use it as-is. Only fall back to defaults if `commands` is nil.

No `missingKeys` entries needed for commands — the array is optional and each entry is self-contained.

### 2. Add `commands` accessor to `Config`

Add a static property:

```swift
static var commands: [ConfigData.CommandConfig] { shared.s.commands ?? [] }
```

### 3. Add `commands` to `ConfigLoader.format()`

Append a `commands:` section after `shortcuts:`. Iterate the command list and emit each entry:

```yaml
  # Custom keyboard shortcuts that run shell commands.
  # Format: shortcut uses modifier+key (e.g. cmd+enter, cmd+shift+t). run is a shell command.
  commands:
    - shortcut: "cmd+enter"
      run: "open -n -a Alacritty"
```

### 4. Create `CommandService`

A minimal service that runs a shell command:

```swift
// Runs shell commands from user-configured keyboard shortcuts.
struct CommandService {
    static func execute(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            do {
                try process.run()
            } catch {
                Logger.shared.log("CommandService: failed to run '\(command)' — \(error.localizedDescription)")
            }
        }
    }
}
```

### 5. Add `enter`/`return` key support to parse

In `KeybindingService.parse()`, add cases to the `switch rawKey` block:

```swift
case "enter", "return": return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 36)
```

Also add to `displayString()` so it renders nicely:

```swift
// After resolving modifiers, before returning:
switch key {
case "enter", "return": displayKey = "↩"
case "left": displayKey = "←"
// ...etc
}
```

### 6. Add duplicate detection and command bindings to `KeybindingService.start()`

After building the `candidates` array, also build command candidates from `Config.commands`. Before creating `Binding` objects, collect all non-empty shortcut strings, normalize them, and check for duplicates.

Normalization: lowercase, split on `+`, sort modifier tokens alphabetically, rejoin. Two shortcuts are duplicates if their normalized form matches.

```swift
func normalize(_ shortcut: String) -> String {
    let tokens = shortcut.lowercased().split(separator: "+").map(String.init)
    guard tokens.count >= 2 else { return shortcut.lowercased() }
    let key = tokens.last!
    let mods = tokens.dropLast().sorted()
    return (mods + [key]).joined(separator: "+")
}
```

If duplicates are found:

```swift
NotificationService.shared.post(
    title: "Shortcut conflict",
    body: "Duplicate shortcut \"\(duplicate)\" — all shortcuts disabled. Fix in config."
)
Logger.shared.log("KeybindingService: duplicate shortcut '\(duplicate)' — all shortcuts disabled")
bindings = []
return
```

If no duplicates, append command bindings:

```swift
for cmd in Config.commands {
    guard let shortcut = cmd.shortcut, !shortcut.isEmpty,
          let run = cmd.run, !run.isEmpty,
          let parsed = parse(shortcut) else { continue }
    bindings.append(Binding(modifiers: parsed.modifiers, key: parsed.key, keyCode: parsed.keyCode, action: {
        CommandService.execute(run)
    }))
}
```

### 7. Config reload already wires through

`KeybindingService.restart()` is already called on config reload (in `UnnamedWindowManagerApp`), so custom commands will be re-registered automatically with the new config values.

---

## Key Technical Notes

- `Process` with `/bin/sh -c` inherits the app's environment, not the user's shell profile. Users who need `$PATH`-dependent commands should use absolute paths or `open -a`.
- `enter`/`return` keyCode 36 is the main Return key; the numpad Enter is keyCode 76 — only main Return is supported for simplicity.
- Duplicate detection must compare built-in and custom shortcuts in the same pass. Modifier aliases (`cmd`/`command`, `opt`/`alt`/`option`, `ctrl`/`control`) need canonical normalization before comparison.
- The `commands` array is not merged element-by-element with defaults — if the user specifies the array, it replaces defaults entirely.

---

## Verification

1. Build the app with no config changes → cmd+Enter opens Alacritty
2. Add a second command in config.yml → reload config → both shortcuts work
3. Set a custom command shortcut to the same value as a built-in shortcut → reload → notification appears, no shortcuts work
4. Fix the duplicate → reload → shortcuts work again
5. Set an empty `shortcut` or `run` → that entry is silently skipped
6. Use `cmd+return` and `cmd+enter` as synonyms → both parse to the same keyCode
