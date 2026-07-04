import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// ax-probe — UI-automation driver for any macOS app via the public Accessibility API.
// Deliberately outside the app's package DAG; it drives a *running* app by bundle id.
//
// Usage: ax-probe <subcommand> --app <bundle-id> [--json]
//   tree [--depth N]                                dump the AX hierarchy (default depth 15)
//   find <axid>                                     locate element by AXIdentifier
//   click <axid>                                    AXPress; CGEvent click fallback
//   type <axid> <text>                              focus + set AXValue, else key events
//   windows                                         list the app's windows
//   screenshot <path> [--window <index-or-title>]   screencapture -l of an app window
//
// --json: human-readable output is unchanged; additionally prints exactly one JSON
// object as the LAST line of stdout.
// Exit codes: 0 ok, 1 failure, 3 identifier/window not found, 5 Accessibility
// permission missing, 64 usage error.

let usageText = """
usage: ax-probe <subcommand> --app <bundle-id> [--json]
  tree [--depth N]                                dump AX hierarchy as indented text / JSON (default depth 15)
  find <axid>                                     locate element whose AXIdentifier == axid
  click <axid>                                    press element (AXPress, CGEvent click fallback)
  type <axid> <text>                              focus element, set value or post key events
  windows                                         list the app's windows (title, frame, main/focused)
  screenshot <path> [--window <index-or-title>]   capture an app window via screencapture -l
exit codes: 0 ok, 1 failure, 3 not found, 5 accessibility permission missing, 64 usage
"""

// MARK: - Output plumbing

/// Prints `object` as exactly one JSON line (the last stdout line, per the probe contract).
func printJSONLine(_ object: [String: Any]) {
    guard
        JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let line = String(data: data, encoding: .utf8)
    else {
        print(#"{"ok":false,"error":"json-encoding-failed"}"#)
        return
    }
    print(line)
}

var jsonOutput = false

@MainActor func fail(_ code: Int32, _ message: String) -> Never {
    print("FAIL: \(message)")
    if jsonOutput {
        printJSONLine(["ok": false, "error": message])
    }
    exit(code)
}

@MainActor func usage(_ message: String? = nil) -> Never {
    if let message { print("error: \(message)") }
    print(usageText)
    if jsonOutput {
        printJSONLine(["ok": false, "error": message ?? "usage"])
    }
    exit(64)
}

// MARK: - AX helpers

let identifierAttribute = "AXIdentifier"

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    copyAttribute(element, name) as? String
}

func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
    copyAttribute(element, name) as? Bool
}

func children(of element: AXUIElement) -> [AXUIElement] {
    guard let raw = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
    return (raw as? [AXUIElement]) ?? []
}

func frame(of element: AXUIElement) -> CGRect? {
    guard
        let posRef = copyAttribute(element, kAXPositionAttribute as String),
        let sizeRef = copyAttribute(element, kAXSizeAttribute as String),
        CFGetTypeID(posRef) == AXValueGetTypeID(),
        CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    // Force-casts are safe: type ids checked above.
    guard
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Best-effort string rendering of an element's AXValue (string, number, bool).
func valueDescription(of element: AXUIElement) -> String? {
    guard let raw = copyAttribute(element, kAXValueAttribute as String) else { return nil }
    if let string = raw as? String { return string }
    if let number = raw as? NSNumber { return number.stringValue }
    return nil
}

func frameDict(_ rect: CGRect) -> [String: Any] {
    ["x": rect.origin.x, "y": rect.origin.y, "w": rect.size.width, "h": rect.size.height]
}

func frameText(_ rect: CGRect?) -> String {
    guard let rect else { return "(no frame)" }
    return String(format: "(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

/// Depth-first search for the element whose AXIdentifier equals `axid`.
func findElement(withIdentifier axid: String, under element: AXUIElement, depth: Int = 120) -> AXUIElement? {
    if stringAttribute(element, identifierAttribute) == axid { return element }
    guard depth > 0 else { return nil }
    for child in children(of: element) {
        if let match = findElement(withIdentifier: axid, under: child, depth: depth - 1) {
            return match
        }
    }
    return nil
}

func describe(_ element: AXUIElement) -> String {
    let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
    var parts = [role]
    if let title = stringAttribute(element, kAXTitleAttribute as String), !title.isEmpty {
        parts.append("'\(title)'")
    }
    if let axid = stringAttribute(element, identifierAttribute), !axid.isEmpty {
        parts.append("[id=\(axid)]")
    }
    if let value = valueDescription(of: element), !value.isEmpty {
        parts.append("value=\(String(value.prefix(60)))")
    }
    parts.append(frameText(frame(of: element)))
    return parts.joined(separator: " ")
}

// MARK: - Target app

@MainActor
func runningApp(bundleID: String) -> NSRunningApplication {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fail(1, "no running app with bundle id \(bundleID)")
    }
    return app
}

@MainActor func requireAccessibility() {
    guard AXIsProcessTrusted() else {
        fail(5, "accessibility permission missing — grant this process in System Settings > Privacy & Security > Accessibility")
    }
}

// MARK: - Subcommands

@MainActor
func runTree(appElement: AXUIElement, maxDepth: Int) {
    func node(_ element: AXUIElement, depth: Int) -> [String: Any] {
        var dict: [String: Any] = ["role": stringAttribute(element, kAXRoleAttribute as String) ?? "?"]
        if let title = stringAttribute(element, kAXTitleAttribute as String), !title.isEmpty { dict["title"] = title }
        if let axid = stringAttribute(element, identifierAttribute), !axid.isEmpty { dict["identifier"] = axid }
        if let value = valueDescription(of: element), !value.isEmpty { dict["value"] = String(value.prefix(200)) }
        if let rect = frame(of: element) { dict["frame"] = frameDict(rect) }
        let kids = children(of: element)
        if !kids.isEmpty, depth < maxDepth {
            dict["children"] = kids.map { node($0, depth: depth + 1) }
        } else if !kids.isEmpty {
            dict["truncatedChildren"] = kids.count
        }
        return dict
    }
    func printHuman(_ element: AXUIElement, depth: Int) {
        print(String(repeating: "  ", count: depth) + describe(element))
        guard depth < maxDepth else { return }
        for child in children(of: element) {
            printHuman(child, depth: depth + 1)
        }
    }
    printHuman(appElement, depth: 0)
    if jsonOutput {
        printJSONLine(["ok": true, "tree": node(appElement, depth: 0)])
    }
    exit(0)
}

@MainActor
func runFind(appElement: AXUIElement, axid: String) {
    guard let element = findElement(withIdentifier: axid, under: appElement) else {
        fail(3, "no element with AXIdentifier '\(axid)'")
    }
    print(describe(element))
    if jsonOutput {
        var dict: [String: Any] = [
            "ok": true,
            "identifier": axid,
            "role": stringAttribute(element, kAXRoleAttribute as String) ?? "?",
        ]
        if let title = stringAttribute(element, kAXTitleAttribute as String), !title.isEmpty { dict["title"] = title }
        if let rect = frame(of: element) { dict["frame"] = frameDict(rect) }
        printJSONLine(dict)
    }
    exit(0)
}

/// Posts a CGEvent left click at a screen point (AX and CGEvent share the
/// top-left-origin global coordinate space, so AX frames can be used directly).
func postClick(at point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    for (type, button) in [(CGEventType.leftMouseDown, CGMouseButton.left), (.leftMouseUp, .left)] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

@MainActor
func runClick(app: NSRunningApplication, appElement: AXUIElement, axid: String) {
    guard let element = findElement(withIdentifier: axid, under: appElement) else {
        fail(3, "no element with AXIdentifier '\(axid)'")
    }
    var actions: CFArray?
    let supportsPress = AXUIElementCopyActionNames(element, &actions) == .success
        && ((actions as? [String]) ?? []).contains(kAXPressAction as String)
    var method = "press"
    if supportsPress, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        print("pressed \(describe(element))")
    } else {
        // Some SwiftUI views expose no AXPress — click the element's center instead.
        guard let rect = frame(of: element) else {
            fail(1, "element '\(axid)' has no AXPress action and no frame to click")
        }
        method = "cgevent"
        app.activate()
        usleep(300_000)
        postClick(at: CGPoint(x: rect.midX, y: rect.midY))
        print("clicked (CGEvent) center of \(describe(element))")
    }
    if jsonOutput {
        printJSONLine(["ok": true, "identifier": axid, "method": method])
    }
    exit(0)
}

/// Posts the text as keyboard CGEvents (unicode string per character).
func postKeystrokes(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
        let chars = Array(String(character).utf16)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            event?.post(tap: .cghidEventTap)
        }
        usleep(15_000)
    }
}

@MainActor
func runType(app: NSRunningApplication, appElement: AXUIElement, axid: String, text: String) {
    guard let element = findElement(withIdentifier: axid, under: appElement) else {
        fail(3, "no element with AXIdentifier '\(axid)'")
    }
    // Focus: try the AX attribute first, fall back to clicking the element.
    var focusable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusable) == .success,
        focusable.boolValue {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    } else if let rect = frame(of: element) {
        app.activate()
        usleep(300_000)
        postClick(at: CGPoint(x: rect.midX, y: rect.midY))
        usleep(200_000)
    }

    var valueSettable = DarwinBoolean(false)
    var method = "setValue"
    if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
        valueSettable.boolValue,
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
        print("set value of \(describe(element))")
    } else {
        method = "keyEvents"
        app.activate()
        usleep(300_000)
        postKeystrokes(text)
        print("typed \(text.count) characters via key events into \(describe(element))")
    }
    if jsonOutput {
        printJSONLine(["ok": true, "identifier": axid, "method": method])
    }
    exit(0)
}

@MainActor
func runWindows(appElement: AXUIElement) {
    guard let raw = copyAttribute(appElement, kAXWindowsAttribute as String),
        let windows = raw as? [AXUIElement] else {
        fail(1, "cannot read app windows (app may have none on screen)")
    }
    var list: [[String: Any]] = []
    for (index, window) in windows.enumerated() {
        let title = stringAttribute(window, kAXTitleAttribute as String) ?? ""
        let rect = frame(of: window)
        let isMain = boolAttribute(window, kAXMainAttribute as String) ?? false
        let isFocused = boolAttribute(window, kAXFocusedAttribute as String) ?? false
        print("[\(index)] '\(title)' \(frameText(rect))\(isMain ? " main" : "")\(isFocused ? " focused" : "")")
        var dict: [String: Any] = ["index": index, "title": title, "main": isMain, "focused": isFocused]
        if let rect { dict["frame"] = frameDict(rect) }
        list.append(dict)
    }
    if jsonOutput {
        printJSONLine(["ok": true, "windows": list])
    }
    exit(0)
}

@MainActor
func runScreenshot(app: NSRunningApplication, path: String, windowSpec: String?) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        fail(1, "CGWindowListCopyWindowInfo failed")
    }
    // Front-to-back list of the app's normal-layer windows.
    let appWindows = info.filter {
        ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
            && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    guard !appWindows.isEmpty else {
        fail(3, "app has no on-screen windows")
    }
    let chosen: [String: Any]
    if let windowSpec {
        if let index = Int(windowSpec) {
            guard index >= 0, index < appWindows.count else {
                fail(3, "window index \(index) out of range (app has \(appWindows.count) windows)")
            }
            chosen = appWindows[index]
        } else {
            guard let match = appWindows.first(where: {
                (($0[kCGWindowName as String] as? String) ?? "").localizedCaseInsensitiveContains(windowSpec)
            }) else {
                fail(3, "no window title matching '\(windowSpec)'")
            }
            chosen = match
        }
    } else {
        chosen = appWindows[0]
    }
    guard let windowID = chosen[kCGWindowNumber as String] as? Int else {
        fail(1, "window has no id")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(windowID), path]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail(1, "screencapture failed to launch: \(error)")
    }
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
        fail(1, "screencapture exited \(process.terminationStatus) or wrote no file — check Screen Recording permission")
    }
    let title = (chosen[kCGWindowName as String] as? String) ?? ""
    print("captured window \(windowID) '\(title)' -> \(path)")
    if jsonOutput {
        printJSONLine(["ok": true, "path": path, "windowID": windowID, "title": title])
    }
    exit(0)
}

// MARK: - Argument parsing + dispatch (top-level code is MainActor)

var argumentList = Array(CommandLine.arguments.dropFirst())
jsonOutput = argumentList.contains("--json")
argumentList.removeAll { $0 == "--json" }

@MainActor
func takeOption(_ name: String) -> String? {
    guard let flagIndex = argumentList.firstIndex(of: name) else { return nil }
    let valueIndex = argumentList.index(after: flagIndex)
    guard valueIndex < argumentList.count else {
        usage("\(name) requires a value")
    }
    let value = argumentList[valueIndex]
    argumentList.remove(at: valueIndex)
    argumentList.remove(at: flagIndex)
    return value
}

let bundleID = takeOption("--app")
let depthOption = takeOption("--depth")
let windowOption = takeOption("--window")

guard let subcommand = argumentList.first else {
    usage()
}
argumentList.removeFirst()

guard let bundleID else {
    usage("--app <bundle-id> is required")
}

let maxDepth: Int
if let depthOption {
    guard let parsed = Int(depthOption), parsed > 0 else {
        usage("--depth must be a positive integer")
    }
    maxDepth = parsed
} else {
    maxDepth = 15
}

let app = runningApp(bundleID: bundleID)

switch subcommand {
case "tree":
    requireAccessibility()
    runTree(appElement: AXUIElementCreateApplication(app.processIdentifier), maxDepth: maxDepth)
case "find":
    guard let axid = argumentList.first else { usage("find requires <axid>") }
    requireAccessibility()
    runFind(appElement: AXUIElementCreateApplication(app.processIdentifier), axid: axid)
case "click":
    guard let axid = argumentList.first else { usage("click requires <axid>") }
    requireAccessibility()
    runClick(app: app, appElement: AXUIElementCreateApplication(app.processIdentifier), axid: axid)
case "type":
    guard argumentList.count >= 2 else { usage("type requires <axid> <text>") }
    requireAccessibility()
    runType(
        app: app,
        appElement: AXUIElementCreateApplication(app.processIdentifier),
        axid: argumentList[0],
        text: argumentList[1]
    )
case "windows":
    requireAccessibility()
    runWindows(appElement: AXUIElementCreateApplication(app.processIdentifier))
case "screenshot":
    guard let path = argumentList.first else { usage("screenshot requires <path>") }
    runScreenshot(app: app, path: path, windowSpec: windowOption)
default:
    usage("unknown subcommand '\(subcommand)'")
}
