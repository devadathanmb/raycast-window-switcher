# Agent guide

Window Switcher is a Raycast extension for finding and controlling individual macOS windows across apps and Spaces.

## Where to work

- `src/window-switcher.tsx`: Raycast UI, preferences, helper calls, feedback, refresh polling.
- `win-ninja/Sources/WinNinja/main.swift`: discovery and Accessibility actions.
- `assets/win-ninja`: compiled helper included in the extension. The internal helper name remains `win-ninja`.
- `WORKING.md`: discovery, permission, and action design. Update it when those behaviors or the helper protocol change.

## Do not break

- The UI calls the helper with `execFile`. `list` returns one JSON array; actions return one JSON `ActionResponse`. Diagnostics go to stderr, not stdout.
- Window actions take `<command> <pid> <window-id>`; app actions take `<command> <pid>`. IDs must be positive. `window-id` is a `CGWindowID`; use `(pid, window-id)` rather than a title or array position because each call re-enumerates windows.
- Close presses the selected window's AX close button, never quits the app. Fullscreen close exits fullscreen, waits for the Space transition, and reacquires the same window ID.
- Focus closes Raycast only after success. Other actions show Toasts and refresh the list. Transition polling uses action-relative 120, 350, and 700 ms deadlines and compares normalized window state.
- Hidden-app filtering and minimized-window filtering are independent. **Show Applications Without Visible Windows** defaults to including windows of hidden apps.
- Cross-Space discovery uses undocumented `_AXUIElementCreateWithRemoteToken`, `_AXUIElementGetWindow`, `CGSMainConnectionID`, and `CGSCopySpacesForWindows`. Keep private declarations isolated; don't describe their behavior as guaranteed by Apple.
- Preserve safety bounds: AX messaging 1 s, helper execution 5 s, remote-token scan 500 IDs / 50 consecutive misses / 50 ms per app. Retry mutating AX actions only if duplicate execution is safe.

## Verify

```bash
npm run typecheck
npm run lint
```

For Swift changes, run `npm run build:swift` to update `assets/win-ninja`, then check `assets/win-ninja list` parses as JSON and malformed arguments fail without invoking destructive actions. For UI changes, run `npm run build` and exercise the interaction in Raycast. The pre-commit hook runs `npm run format` and `npm run lint` but not typecheck.

Keep TypeScript focused on UI and protocol handling; keep macOS behavior in Swift. License: GPL-3.0-only.
