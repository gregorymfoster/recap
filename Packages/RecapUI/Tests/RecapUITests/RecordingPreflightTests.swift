import RecapAudio
import Testing
@testable import RecapUI

@Suite struct RecordingPreflightTests {
    // MARK: - needsProbe

    @Test(arguments: [
        (false, nil as Bool?, false),
        (false, true, false),
        (false, false, false),
        (true, nil, true),
        (true, true, true),
        (true, false, false),
    ])
    func needsProbeMatrix(includeSystemAudio: Bool, lastTapFailed: Bool?, expected: Bool) {
        #expect(
            RecordingPreflight.needsProbe(includeSystemAudio: includeSystemAudio, lastTapFailed: lastTapFailed)
                == expected
        )
    }

    // MARK: - decide: exhaustive micGranted x systemAudioEnabled x probeResult

    @Test(arguments: [
        // micGranted, systemAudioEnabled, probeResult, expected outcome
        (true, false, nil as SystemAudioProbeResult?, RecordingPreflight.Outcome.proceed(includeMic: true, includeSystemAudio: false)),
        (true, false, .captured, .proceed(includeMic: true, includeSystemAudio: false)),
        (true, false, .denied, .proceed(includeMic: true, includeSystemAudio: false)),
        (true, false, .failed("x"), .proceed(includeMic: true, includeSystemAudio: false)),

        (true, true, nil, .proceed(includeMic: true, includeSystemAudio: true)),
        (true, true, .captured, .proceed(includeMic: true, includeSystemAudio: true)),
        (true, true, .denied, .proceed(includeMic: true, includeSystemAudio: false)),
        (true, true, .failed("x"), .proceed(includeMic: true, includeSystemAudio: false)),

        (false, false, nil, .blocked),
        (false, false, .captured, .blocked),
        (false, false, .denied, .blocked),
        (false, false, .failed("x"), .blocked),

        (false, true, nil, .proceed(includeMic: false, includeSystemAudio: true)),
        (false, true, .captured, .proceed(includeMic: false, includeSystemAudio: true)),
        (false, true, .denied, .blocked),
        (false, true, .failed("x"), .blocked),
    ])
    func decideMatrix(
        micGranted: Bool, systemAudioEnabled: Bool, probeResult: SystemAudioProbeResult?,
        expected: RecordingPreflight.Outcome
    ) {
        #expect(
            RecordingPreflight.decide(
                micGranted: micGranted, systemAudioEnabled: systemAudioEnabled, probeResult: probeResult
            ) == expected
        )
    }
}
