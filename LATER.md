# LATER

## Hardcoded delays audit

Several `asyncAfter` delays in the codebase are hardcoded magic numbers rather than being derived from `Config.animationDuration`. This can cause subtle timing bugs if animation speed is changed in config.

### Already derived from config — ok

| File | Delay | Purpose |
|------|-------|---------|
| `Services/Observation/DragReapplyScheduler.swift` | `max(0.3, animDur + 0.1)` etc. | Post-drag reapply, scales with animation |
| `Services/ReapplyHandler.swift` | `max(0.2, animDur + 0.05)` etc. | Reapply settle, scales with animation |
| `Services/Window/AnimationService.swift:199` | `Config.animatedOnceTTL` (0.25s) | Animated-once TTL cache |
| `Services/Scrolling/ScrollingAnimationService.swift:326` | `Config.animatedOnceTTL` | Same |

### Replaced with SettlePoller — resolved

| File | Was | Resolution |
|------|-----|------------|
| `Services/AutoMode/AutoModeHandler.swift` | `0.3` fixed | SettlePoller: poll until frame matches target |
| `Services/ReapplyHandler.swift` | `0.3` fixed (pass 2→3) | SettlePoller: poll until refusal windows settle |
| `Services/Window/PostResizeValidator.swift` | `0.2` fixed | SettlePoller: poll until frame stabilises |
| `Services/Observation/FocusObserver.swift` | `0.15` fixed | SettlePoller: poll until hash in CGWindowList |
| `Services/Handlers/TileAllHandler.swift` | `0.5` fixed | Removed — notification now posted immediately |

### Intentional fixed delays — likely fine as-is

| File | Delay | Purpose |
|------|-------|---------|
| `Services/Observation/DragReapplyScheduler.swift:54` | `0.01` | Debounce drag events |
| `Services/ReapplyHandler.swift:76` | `0.01` | Debounce reapply calls |
| `Services/Scrolling/ScrollingAnimationService.swift:107` | `0.05` | Short settle before scroll layout |
| `Services/Handlers/ScrollAllHandler.swift` | `delay * i` | Stagger per-window scroll-all additions |
| `Services/AutoMode/AutoModeHandler.swift:51,60` | `0.1` | Poll interval waiting for window CGWindowID |
