import Carbon.HIToolbox
import Testing
@testable import RecapUI

@Suite struct GlobalHotKeyTests {
    /// Registration succeeds and tears down cleanly. Uses an unlikely combo
    /// (⌃⌥⇧F18) so the test never collides with a real app's hot key.
    @MainActor
    @Test func registersAndUnregisters() {
        let hotKey = GlobalHotKey(
            keyCode: kVK_F18, modifiers: controlKey | optionKey | shiftKey
        ) {}
        #expect(hotKey != nil)
    }

    /// The handler actually fires: synthesize the Carbon hot-key event and
    /// send it to the application event target, exactly as the system would.
    @MainActor
    @Test func handlerFiresOnHotKeyEvent() {
        var fired = false
        let hotKey = GlobalHotKey(
            keyCode: kVK_F17, modifiers: controlKey | optionKey | shiftKey
        ) { fired = true }
        #expect(hotKey != nil)

        var event: OpaquePointer?
        CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
            EventAttributes(kEventAttributeNone), &event
        )
        var hotKeyID = EventHotKeyID(signature: OSType(0x5243_4150), id: 1)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID
        )
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)

        #expect(fired)
    }
}
