// input.swift — post keyboard CGEvents. Needs only the Accessibility TCC grant
// (AXIsProcessTrusted) — no Apple Events / System Events / Automation grant.
//
// Slimmed deliberately: clicking and typing by accessibility identifier now go through
// `Tools/AXProbe` (ax-probe click/type --pid). This helper keeps only the handful of
// actions ax-probe can't do — bringing an instance to the front, and posting a keyboard
// shortcut for the rare screen with no reasonable AX path (e.g. ⌘, for Settings).
//
// Compile once (launch.sh does this): swiftc -O -o build/screenshots/input input.swift
//
// Usage:
//   input activate <pid|bundle-id>        bring an app to the front. Prefer the PID from
//                                         launch.sh — a bundle id is ambiguous when the
//                                         user's installed copy of the app is also running.
//   input key <keycode> [cmd] [shift] [opt] [ctrl]
//       common keycodes: 36 Return, 48 Tab, 53 Esc, 40 k (⌘K search), 43 , (⌘, settings)

import AppKit
import CoreGraphics

func post(_ e: CGEvent?) {
    e?.post(tap: .cghidEventTap)
    usleep(50_000)
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(64)
}

// The synthetic HID event stream tracks modifier state independently of any one event's
// `.flags` field: a keyDown posted with .maskCommand set latches Cmd in that stream until
// something explicitly clears it, regardless of what flags later events carry. Without this,
// a ⌘K chord leaves Cmd stuck "down" and subsequent plain-letter keystrokes get delivered as
// ⌘-shortcuts. Call this after any chord/shortcut so the stream returns to a known
// zero-modifier state before the command returns.
func clearModifiers() {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    e?.type = .flagsChanged
    e?.flags = []
    post(e)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: input activate|key ...") }

switch args[1] {
case "activate":
    guard args.count >= 3 else { die("activate <pid|bundle-id>") }
    let app: NSRunningApplication?
    if let pid = Int32(args[2]) {
        app = NSRunningApplication(processIdentifier: pid)
    } else {
        app = NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).first
    }
    guard let app else { die("app not running: \(args[2])") }
    app.activate(options: [])
    usleep(400_000)

case "key":
    guard args.count >= 3, let raw = UInt16(args[2]) else { die("key <keycode> [cmd|shift|opt|ctrl]...") }
    var flags: CGEventFlags = []
    for m in args.dropFirst(3) {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: die("unknown modifier: \(m)")
        }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(raw), keyDown: down)
        e?.flags = flags
        post(e)
    }
    // Always end on an explicit zero-flags state, even for bare (no-modifier) keys — cheap
    // insurance against a stuck flag from this or any earlier command in the process.
    clearModifiers()

default:
    die("unknown command: \(args[1])")
}
