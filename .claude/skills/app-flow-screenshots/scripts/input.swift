// input.swift — post keyboard/mouse events via CGEvent. Needs only the Accessibility
// TCC grant (AXIsProcessTrusted) — no Apple Events / System Events / Automation grant.
//
// Compile once (launch.sh does this): swiftc -O -o build/screenshots/input input.swift
//
// Usage:
//   input activate <pid|bundle-id>        bring an app to the front. Prefer the PID from
//                                         launch.sh — a bundle id is ambiguous when the
//                                         user's installed copy of the app is also running.
//   input click <x> <y>                   left-click at screen coords (points, origin top-left)
//   input doubleclick <x> <y>
//   input key <keycode> [cmd] [shift] [opt] [ctrl]
//       common keycodes: 36 Return, 48 Tab, 53 Esc, 121 PageDown, 116 PageUp,
//       125 Down, 126 Up, 40 k (⌘K search), 43 , (⌘, settings)
//   input type <text>                     type literal text into the focused element
//   input scroll <x> <y> <dy>             scroll at coords; negative dy scrolls content down

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
// a ⌘K chord leaves Cmd stuck "down" and subsequent plain-letter keystrokes (e.g. from `type`)
// get delivered as ⌘-shortcuts. Call this after any chord/shortcut so the stream returns to a
// known zero-modifier state before the command returns.
func clearModifiers() {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    e?.type = .flagsChanged
    e?.flags = []
    post(e)
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: input activate|click|doubleclick|key|type|scroll ...") }

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

case "click", "doubleclick":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { die("click <x> <y>") }
    let p = CGPoint(x: x, y: y)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    usleep(150_000)
    let clicks = args[1] == "doubleclick" ? 2 : 1
    for i in 1...clicks {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(e)
        }
    }

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

case "type":
    guard args.count >= 3 else { die("type <text>") }
    // Text entry must never inherit ambient modifier state left over from a previous chord:
    // clear it up front, then give every keyDown/keyUp exactly the flags that character needs
    // (shift for uppercase/symbols, nothing otherwise) rather than whatever flags happen to be
    // latched in the synthetic event stream.
    clearModifiers()
    for scalar in args[2].unicodeScalars {
        let charFlags: CGEventFlags = scalar.properties.isUppercase ? [.maskShift] : []
        var chars = Array(String(scalar).utf16)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.flags = charFlags
            e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            post(e)
        }
    }
    clearModifiers()

case "scroll":
    guard args.count >= 5, let x = Double(args[2]), let y = Double(args[3]), let dy = Int32(args[4])
    else { die("scroll <x> <y> <dy>") }
    let p = CGPoint(x: x, y: y)
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    usleep(150_000)
    var remaining = dy
    while remaining != 0 {
        let step = remaining > 0 ? min(remaining, 40) : max(remaining, -40)
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: step, wheel2: 0, wheel3: 0)
        e?.location = p
        post(e)
        remaining -= step
    }

default:
    die("unknown command: \(args[1])")
}
