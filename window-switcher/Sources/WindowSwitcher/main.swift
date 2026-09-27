import ApplicationServices
import Cocoa
import Foundation

// Undocumented macOS APIs (same technique as AltTab - lwouis/alt-tab-macos).
// @_silgen_name links directly to private C symbols that aren't in any public header.

// Creates an AXUIElement from a raw token — lets us find windows on other Spaces.
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

// Bridges AXUIElement -> CGWindowID so we can cross-reference with CGWindowList.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>)
    -> AXError

// Session connection ID, required by other private Space APIs.
@_silgen_name("CGSMainConnectionID")
func cgsMainConnectionID() -> Int

// Returns which Space(s) a window belongs to. Windows without a Space are browser
// tabs (they get a CGWindowID but no Space assignment).
@_silgen_name("CGSCopySpacesForWindows")
func cgsCopySpacesForWindows(_ cid: Int, _ selector: Int, _ windowIDs: CFArray) -> CFArray?

typealias AXUIElementID = UInt64

struct WindowInfo: Codable {
    let processName: String
    let windowTitle: String
    let appPath: String
    let pid: Int32
    let windowId: CGWindowID
    let isMinimized: Bool
    let isFullscreen: Bool
    let isAppHidden: Bool
}

struct ResolvedWindow {
    let element: AXUIElement
    let title: String
    let windowId: CGWindowID
}

struct ActionResponse: Codable {
    let success: Bool
    let error: String?

    static func succeeded() -> ActionResponse {
        ActionResponse(success: true, error: nil)
    }

    static func failed(_ error: String) -> ActionResponse {
        ActionResponse(success: false, error: error)
    }
}

func printJSON<T: Encodable>(_ value: T) {
    do {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        print(json)
    } catch {
        fputs("Failed to encode helper response: \(error)\n", stderr)
        exit(1)
    }
}

func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, attribute, &value)
    if err == .success, let flag = value as? Bool {
        return flag
    }
    return nil
}

func isMinimized(_ element: AXUIElement) -> Bool {
    return boolAttribute(element, kAXMinimizedAttribute as CFString) ?? false
}

func isFullscreen(_ element: AXUIElement) -> Bool {
    return boolAttribute(element, "AXFullScreen" as CFString) ?? false
}

func getTitle(of element: AXUIElement) -> String {
    var titleValue: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
    if err == .success, let title = titleValue as? String {
        return title
    }
    return ""
}

func getWindowID(of element: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &windowID)
    return err == .success && windowID != 0 ? windowID : nil
}

// In practice, this can omit windows on inactive Spaces.
func axWindows(for pid: pid_t) -> [AXUIElement] {
    let appElement = AXUIElementCreateApplication(pid)
    var windowsValue: AnyObject?
    let err = AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &windowsValue)
    if err == .success, let windows = windowsValue as? [AXUIElement] {
        return windows
    }
    return []
}

// kAXWindows can omit inactive-Space windows. The private token API has no
// enumeration entry point, so other-Space acquisition scans observed element IDs.
// The 500-ID, 50-miss, and 50ms bounds keep one uncooperative app from dominating a list call.
func windowsByBruteForce(for pid: pid_t) -> [AXUIElement] {
    // AltTab's reverse-engineered token: pid, zero, numeric marker, then element ID.
    var remoteToken = Data(count: 20)
    remoteToken.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    remoteToken.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
    remoteToken.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })

    var results: [AXUIElement] = []
    let startTime = CFAbsoluteTimeGetCurrent()
    var consecutiveMisses = 0

    // Try element IDs 0, 1, 2, 3... until we hit 500, spend 50ms, or
    // see 50 consecutive misses (IDs cluster in low numbers, so gaps mean we're done).
    for elementId: AXUIElementID in 0..<500 {
        if consecutiveMisses >= 50 { break }
        if CFAbsoluteTimeGetCurrent() - startTime > 0.05 { break }

        remoteToken.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })

        guard
            let axElement = _AXUIElementCreateWithRemoteToken(remoteToken as CFData)?
                .takeRetainedValue()
        else {
            consecutiveMisses += 1
            continue
        }
        consecutiveMisses = 0

        var subroleValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            axElement, kAXSubroleAttribute as CFString, &subroleValue)
        guard err == .success, let subrole = subroleValue as? String else { continue }

        if subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String {
            results.append(axElement)
        }
    }

    return results
}

// Single pass over CGWindowList to get:
// - realWIDs: windows assigned to a Space (actual windows, not browser tabs)
// - pidsWithWindows: which PIDs have windows, so we can skip brute-forcing the rest
// - realWindowCountByPid: how many real windows each PID owns (used to skip brute-force)
func cgWindowScan() -> (
    realWIDs: Set<CGWindowID>, pidsWithWindows: Set<pid_t>,
    realWindowCountByPid: [pid_t: Int]
) {
    let conn = cgsMainConnectionID()
    var realWIDs = Set<CGWindowID>()
    var pidsWithWindows = Set<pid_t>()
    var realWindowCountByPid: [pid_t: Int] = [:]

    guard
        let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    else { return (realWIDs, pidsWithWindows, realWindowCountByPid) }

    for info in windowInfoList {
        guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0
        else { continue }  // layer 0 = normal windows

        let ownerPid = info[kCGWindowOwnerPID as String] as? Int32
        if let ownerPid = ownerPid {
            pidsWithWindows.insert(ownerPid)
        }

        // Check if this window is assigned to a macOS Space.
        // Real windows belong to a Space. Browser tabs get a CGWindowID but NO Space assignment.
        // This is how we tell them apart.
        let widArray = [wid] as CFArray
        if let spaces = cgsCopySpacesForWindows(conn, 0x7, widArray) as? [UInt64],
            !spaces.isEmpty
        {
            realWIDs.insert(wid)  // This window has a Space → it's real, not a tab
            if let ownerPid = ownerPid {
                realWindowCountByPid[ownerPid, default: 0] += 1
            }
        }
    }

    return (realWIDs, pidsWithWindows, realWindowCountByPid)
}

// Merges standard and brute-force results, deduplicating by stable CGWindowID.
func allWindows(for pid: pid_t, realWIDs: Set<CGWindowID>, expectedCount: Int)
    -> [ResolvedWindow]
{
    let standard = axWindows(for: pid)
    var seenWindowIDs = Set<CGWindowID>()
    var combined: [ResolvedWindow] = []

    for window in standard {
        let title = getTitle(of: window)
        guard !title.isEmpty, let windowId = getWindowID(of: window) else { continue }
        guard seenWindowIDs.insert(windowId).inserted else { continue }
        combined.append(ResolvedWindow(element: window, title: title, windowId: windowId))
    }

    if seenWindowIDs.count >= expectedCount {
        return combined
    }

    for window in windowsByBruteForce(for: pid) {
        let title = getTitle(of: window)
        guard !title.isEmpty, let windowId = getWindowID(of: window) else { continue }
        guard !seenWindowIDs.contains(windowId), realWIDs.contains(windowId) else { continue }
        seenWindowIDs.insert(windowId)
        combined.append(ResolvedWindow(element: window, title: title, windowId: windowId))
    }

    return combined
}

func listWindows() -> [WindowInfo] {
    let (realWIDs, pidsWithWindows, realWindowCountByPid) = cgWindowScan()

    struct AppEntry {
        let name: String
        let path: String
        let pid: pid_t
        let isHidden: Bool
    }

    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppEntry? in
        guard app.activationPolicy == .regular else { return nil }
        guard app.bundleIdentifier != "com.raycast.macos" else { return nil }
        let pid = app.processIdentifier
        guard pidsWithWindows.contains(pid) else { return nil }
        return AppEntry(
            name: app.localizedName ?? "",
            path: app.bundleURL?.path ?? "",
            pid: pid,
            isHidden: app.isHidden
        )
    }

    let lock = NSLock()
    var allResults: [WindowInfo] = []

    DispatchQueue.concurrentPerform(iterations: apps.count) { index in
        let app = apps[index]
        let expectedCount = realWindowCountByPid[app.pid] ?? 0
        let windows = allWindows(for: app.pid, realWIDs: realWIDs, expectedCount: expectedCount)
        let localResults = windows.map { window in
            WindowInfo(
                processName: app.name,
                windowTitle: window.title,
                appPath: app.path,
                pid: app.pid,
                windowId: window.windowId,
                isMinimized: isMinimized(window.element),
                isFullscreen: isFullscreen(window.element),
                isAppHidden: app.isHidden
            )
        }

        lock.lock()
        allResults.append(contentsOf: localResults)
        lock.unlock()
    }

    allResults.sort {
        let processOrder = $0.processName.localizedCaseInsensitiveCompare($1.processName)
        if processOrder != .orderedSame {
            return processOrder == .orderedAscending
        }

        let titleOrder = $0.windowTitle.localizedCaseInsensitiveCompare($1.windowTitle)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        return $0.windowId < $1.windowId
    }
    return allResults
}

func resolveWindow(pid: pid_t, windowId: CGWindowID) -> ResolvedWindow? {
    let (realWIDs, _, realWindowCountByPid) = cgWindowScan()
    let expectedCount = realWindowCountByPid[pid] ?? 0
    return allWindows(for: pid, realWIDs: realWIDs, expectedCount: expectedCount)
        .first { $0.windowId == windowId }
}

func focusWindow(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let window = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return .failed("Application not found")
    }

    _ = app.activate()
    let error = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    return error == .success ? .succeeded() : .failed("Failed to focus window")
}

func closeWindow(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let resolved = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }

    var window = resolved.element
    if isFullscreen(window) {
        let fullscreenError = AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString, kCFBooleanFalse)
        guard fullscreenError == .success else {
            return .failed("Failed to exit full screen before closing window")
        }

        usleep(1_000_000)
        guard let refreshed = resolveWindow(pid: pid, windowId: windowId) else {
            return .failed("Window not found after exiting full screen")
        }
        window = refreshed.element
    }

    var closeButtonValue: AnyObject?
    let copyError = AXUIElementCopyAttributeValue(
        window, kAXCloseButtonAttribute as CFString, &closeButtonValue)
    guard copyError == .success,
        let closeButtonValue,
        CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID()
    else {
        return .failed("Window does not expose a close button")
    }
    let closeButton = closeButtonValue as! AXUIElement

    let pressError = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
    return pressError == .success
        ? .succeeded()
        : .failed("Failed to close window")
}

func minimizeWindow(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let resolved = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }

    var window = resolved.element
    if isFullscreen(window) {
        _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        usleep(250_000)
    }

    for _ in 0..<10 {
        let error = AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if error == .success || boolAttribute(window, kAXMinimizedAttribute as CFString) == true {
            return .succeeded()
        }

        usleep(200_000)
        if let refreshed = resolveWindow(pid: pid, windowId: windowId) {
            window = refreshed.element
        }
    }

    return .failed("Failed to minimize window")
}

func maximizeWindow(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let window = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }

    let error = AXUIElementSetAttributeValue(
        window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    if error == .success
        || boolAttribute(window.element, kAXMinimizedAttribute as CFString) == false
    {
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        return .succeeded()
    }
    return .failed("Failed to maximize window")
}

func makeWindowFullscreen(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let window = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }

    let error = AXUIElementSetAttributeValue(
        window.element, "AXFullScreen" as CFString, kCFBooleanTrue)
    return error == .success
        ? .succeeded()
        : .failed("Failed to make window full screen")
}

func exitWindowFullscreen(pid: pid_t, windowId: CGWindowID) -> ActionResponse {
    guard let window = resolveWindow(pid: pid, windowId: windowId) else {
        return .failed("Window not found")
    }

    let error = AXUIElementSetAttributeValue(
        window.element, "AXFullScreen" as CFString, kCFBooleanFalse)
    return error == .success
        ? .succeeded()
        : .failed("Failed to exit full screen")
}

func hideApplication(pid: pid_t) -> ActionResponse {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return .failed("Application not found")
    }
    return app.hide() ? .succeeded() : .failed("Failed to hide application")
}

func showApplication(pid: pid_t) -> ActionResponse {
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        return .failed("Application not found")
    }

    let unhidden = app.unhide()
    let activated = app.activate()
    return unhidden || activated ? .succeeded() : .failed("Failed to show application")
}

func printHelp() {
    let help = """
        Usage: window-switcher <command> [arguments]

        Commands:
          list                            Output JSON for all open windows
          focus <pid> <window-id>         Activate and raise a window
          close <pid> <window-id>         Close a window
          minimize <pid> <window-id>      Minimize a window
          maximize <pid> <window-id>      Unminimize a window
          fullscreen <pid> <window-id>    Make a window full screen
          unfullscreen <pid> <window-id>  Exit full screen for a window
          hide-app <pid>                  Hide an application
          show-app <pid>                  Unhide an application
        """
    print(help)
}

func parsePidAndWindowId(command: String) -> (pid: pid_t, windowId: CGWindowID) {
    let arguments = CommandLine.arguments
    guard arguments.count >= 4,
        let pid = Int32(arguments[2]),
        pid > 0,
        let windowId = UInt32(arguments[3]),
        windowId != kCGNullWindowID
    else {
        printJSON(ActionResponse.failed("Usage: window-switcher \(command) <pid> <window-id>"))
        exit(2)
    }
    return (pid, windowId)
}

func parsePid(command: String) -> pid_t {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3,
        let pid = Int32(arguments[2]),
        pid > 0
    else {
        printJSON(ActionResponse.failed("Usage: window-switcher \(command) <pid>"))
        exit(2)
    }
    return pid
}

_ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    printHelp()
    exit(0)
}

switch arguments[1] {
case "list":
    printJSON(listWindows())

case "focus":
    let target = parsePidAndWindowId(command: "focus")
    printJSON(focusWindow(pid: target.pid, windowId: target.windowId))

case "close":
    let target = parsePidAndWindowId(command: "close")
    printJSON(closeWindow(pid: target.pid, windowId: target.windowId))

case "minimize":
    let target = parsePidAndWindowId(command: "minimize")
    printJSON(minimizeWindow(pid: target.pid, windowId: target.windowId))

case "maximize":
    let target = parsePidAndWindowId(command: "maximize")
    printJSON(maximizeWindow(pid: target.pid, windowId: target.windowId))

case "fullscreen":
    let target = parsePidAndWindowId(command: "fullscreen")
    printJSON(makeWindowFullscreen(pid: target.pid, windowId: target.windowId))

case "unfullscreen":
    let target = parsePidAndWindowId(command: "unfullscreen")
    printJSON(exitWindowFullscreen(pid: target.pid, windowId: target.windowId))

case "hide-app":
    printJSON(hideApplication(pid: parsePid(command: "hide-app")))

case "show-app":
    printJSON(showApplication(pid: parsePid(command: "show-app")))

default:
    printHelp()
    exit(2)
}
