import Foundation
import RecapCore
import RecapTranscription

// Eval harness for transcription quality: runs the configured WhisperKit
// model over fixture (audio, reference.txt) pairs and scores the output by
// word error rate (WER), so model/prompt changes are measurable instead of
// vibes (M7). Mirrors EnhanceEval's structure/exit conventions.
//
// Run: swift run transcribe-eval [--json] [fixtures-dir]
// Default fixtures-dir: ../../Fixtures/transcribe (from the package directory).
//
// Each case dir has:
//   reference.txt      — ground-truth transcript text.
//   expectations.json  — {"maxWER": 0.25, "model": "tiny", "audio": "relative/or/absolute/path.m4a"}
// `audio` is optional; when absent the case dir's own `audio.m4a` is used if
// present, else falls back to `Fixtures/meeting-fixture.m4a` (repo-relative)
// so existing fixture audio isn't duplicated.
//
// --json: in addition to the normal human-readable output, prints exactly one
// JSON object as the LAST line of stdout, e.g.:
//   {"ok":false,"cases":[{"name":"meeting-fixture","wer":0.18,"maxWER":0.25,"passed":true}]}
// Exit codes: 0 all cases within maxWER, 1 some case(s) exceeded maxWER or
// failed to transcribe, 64 usage error, 66 missing fixtures dir.

struct Expectations: Decodable {
    var maxWER: Double
    var model: String
    var audio: String?
}

/// Per-case machine-readable summary for `--json`.
struct CaseSummary: Codable {
    var name: String
    var wer: Double?
    var maxWER: Double
    var passed: Bool
}

struct EvalResult: Codable {
    var ok: Bool
    var cases: [CaseSummary]
}

func printJSON(_ result: EvalResult) {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

struct CaseResult {
    var name: String
    var wer: Double
    var maxWER: Double
    var seconds: Double
    var passed: Bool
}

func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

/// Resolves the audio file for a case: explicit `expectations.audio` (relative
/// to the case dir if not absolute), else `<caseDir>/audio.m4a` if present,
/// else the shared `Fixtures/meeting-fixture.m4a` (repo-relative, resolved
/// via #filePath so it works regardless of cwd).
func resolveAudioURL(caseDir: URL, expectations: Expectations) -> URL {
    if let audio = expectations.audio {
        if audio.hasPrefix("/") {
            return URL(fileURLWithPath: audio)
        }
        return caseDir.appendingPathComponent(audio)
    }
    let ownAudio = caseDir.appendingPathComponent("audio.m4a")
    if FileManager.default.fileExists(atPath: ownAudio.path) {
        return ownAudio
    }
    // Packages/RecapTranscription/Sources/TranscribeEval/main.swift -> repo root.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return repoRoot.appendingPathComponent("Fixtures/meeting-fixture.m4a")
}

@MainActor
func evaluate(name: String, dir: URL, manager: WhisperModelManager) async throws -> CaseResult {
    let decoder = JSONDecoder()
    let expectations = try decoder.decode(
        Expectations.self, from: Data(contentsOf: dir.appendingPathComponent("expectations.json"))
    )
    let reference = try String(contentsOf: dir.appendingPathComponent("reference.txt"), encoding: .utf8)
    let audioURL = resolveAudioURL(caseDir: dir, expectations: expectations)

    guard let model = ModelCatalog.info(for: expectations.model) else {
        throw EvalError.unknownModel(expectations.model)
    }

    if manager.installedFolder(for: model) == nil {
        print("  downloading \(model.displayName)…")
        manager.download(model)
        while case .downloading(let fraction) = manager.states[model.id] ?? .available {
            print(String(format: "    %3.0f%%", fraction * 100))
            try? await Task.sleep(for: .seconds(2))
        }
        guard manager.states[model.id] == .installed else {
            throw EvalError.downloadFailed(model.id)
        }
    }
    manager.setActive(model.id)

    guard let engine = manager.activeEngine() else {
        throw EvalError.noEngine(model.id)
    }

    let started = Date.now
    let transcript = try await engine.transcribe(file: audioURL) { _ in }
    let seconds = Date.now.timeIntervalSince(started)

    let wer = WordErrorRate.wer(reference: reference, hypothesis: transcript.fullText)
    let passed = wer <= expectations.maxWER
    return CaseResult(name: name, wer: wer, maxWER: expectations.maxWER, seconds: seconds, passed: passed)
}

enum EvalError: Error, CustomStringConvertible {
    case unknownModel(String)
    case downloadFailed(String)
    case noEngine(String)

    var description: String {
        switch self {
        case .unknownModel(let id): return "unknown model id: \(id)"
        case .downloadFailed(let id): return "download did not complete: \(id)"
        case .noEngine(let id): return "no engine for installed model: \(id)"
        }
    }
}

// MARK: - Main

@MainActor
func run() async {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let jsonOutput = arguments.contains("--json")
    arguments.removeAll { $0 == "--json" }

    let fixturesDir = URL(fileURLWithPath: arguments.first ?? "../../Fixtures/transcribe")
    guard FileManager.default.fileExists(atPath: fixturesDir.path) else {
        print("fixtures directory not found: \(fixturesDir.path)")
        exit(66)
    }

    let caseDirs: [URL]
    do {
        caseDirs = try FileManager.default
            .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        print("failed to list fixtures directory: \(error)")
        exit(66)
    }

    let manager = WhisperModelManager()
    var failures = 0
    var caseSummaries: [CaseSummary] = []
    for dir in caseDirs {
        let name = dir.lastPathComponent
        print("— \(name) —")
        do {
            let result = try await evaluate(name: name, dir: dir, manager: manager)
            let line = String(
                format: "%-18s wer %.3f (max %.2f) %@  (%.1fs)",
                (name as NSString).utf8String!, result.wer, result.maxWER,
                mark(result.passed), result.seconds
            )
            print(line)
            if !result.passed { failures += 1 }
            caseSummaries.append(CaseSummary(name: name, wer: result.wer, maxWER: result.maxWER, passed: result.passed))
        } catch {
            print("\(name): FAILED — \(error)")
            failures += 1
            caseSummaries.append(CaseSummary(name: name, wer: nil, maxWER: 0, passed: false))
        }
    }
    print(failures == 0 ? "\nall cases passed" : "\n\(failures) case(s) exceeded maxWER or failed")
    if jsonOutput {
        printJSON(EvalResult(ok: failures == 0, cases: caseSummaries))
    }
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
