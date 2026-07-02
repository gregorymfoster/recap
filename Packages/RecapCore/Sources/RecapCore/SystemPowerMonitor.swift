import Foundation
import IOKit.ps

/// Watches battery, Low Power Mode, and thermal state, emitting a
/// `PowerState` whenever any of them change (plus a slow poll as a backstop
/// for AC plug/unplug, which has no reliable notification).
@MainActor
public final class SystemPowerMonitor {
    private var pollTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    public init() {}

    public nonisolated static func currentState() -> PowerState {
        let providing = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let thermal = ProcessInfo.processInfo.thermalState
        return PowerState(
            onBattery: providing == kIOPMBatteryPowerKey,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalPressure: thermal == .serious || thermal == .critical
        )
    }

    /// Emits the current state immediately, then on every change.
    public func updates() -> AsyncStream<PowerState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PowerState.self)
        _ = continuation.yield(Self.currentState())

        let push = { @Sendable in
            _ = continuation.yield(Self.currentState())
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { _ in push() },
            center.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
            ) { _ in push() },
        ]
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                push()
            }
        }
        continuation.onTermination = { @Sendable _ in
            Task { @MainActor in
                // Monitor owns one consumer (the queue store); tear down with it.
                self.stop()
            }
        }
        return stream
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}
