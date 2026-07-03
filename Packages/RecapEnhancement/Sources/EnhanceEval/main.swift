import Foundation
import RecapCore
import RecapEnhancement

// Eval harness for enhancement quality: runs the enhancer over fixture
// (transcript, notes) pairs and scores the output on deterministic proxies,
// so prompt changes are measurable instead of vibes.
//
// Run: swift run enhance-eval [--runs N] [fixtures-dir]
// Default fixtures-dir: ../../Fixtures/enhance (from the package directory).
//
// Metrics per case:
//   structure — one output bullet per rough-note line (the enhancer's core
//               contract; only checked when the case has notes)
//   recall    — expectations.mustContain strings present (case-insensitive)
//   meta      — no meta-narration ("the digest", "as an AI", …) and no
//               expectations.mustNotContain strings
//   numbers   — every number in the output also appears in the transcript
//               or notes (cheap hallucination signal)
//   subtitle  — a one-line subtitle was generated: non-nil, non-empty,
//               <= 120 chars, and free of meta-narration phrases

struct Expectations: Decodable {
    var mustContain: [String]?
    var mustNotContain: [String]?
}

// --json: in addition to the normal human-readable output, prints exactly one
// JSON object as the LAST line of stdout, e.g.:
//   {"ok":false,"cases":[{"name":"budget-sync","structure":true,"recall":true,"meta":true,"numbers":false,"subtitle":true}]}
// `structure` is omitted (null) for cases with no rough notes, matching the
// human "structure —" line. Exit codes are unchanged.

/// Per-case machine-readable summary for `--json`.
struct CaseSummary: Codable {
    var name: String
    var structure: Bool?
    var recall: Bool
    var meta: Bool
    var numbers: Bool
    var subtitle: Bool
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
    var structureOK: Bool?
    var recallHits: Int
    var recallTotal: Int
    var metaOK: Bool
    var numbersOK: Bool
    var subtitleOK: Bool
    /// "Also discussed" bullets that restate a rewritten-notes bullet.
    var duplicateExtras: Int
    var seconds: Double
    var output: String
}

let metaPhrases = ["the digest", "the note", "as an ai", "i cannot", "transcript portion", "the user's"]

/// Digit tokens, normalized: internal separators stripped, "40k" → 40000.
func numberTokens(in text: String) -> Set<String> {
    var tokens: Set<String> = []
    for match in text.matches(of: /(\d[\d,.]*)(k\b)?/.ignoresCase()) {
        let digits = String(match.output.1)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !digits.isEmpty else { continue }
        tokens.insert(digits)
        if match.output.2 != nil, let value = Int(digits) {
            tokens.insert(String(value * 1000))
        }
    }
    return tokens
}

/// Values of spelled-out numbers ("forty thousand" → 40000, "eight" → 8),
/// so word-form transcripts don't flag digit-form outputs as hallucinated.
func wordNumberValues(in text: String) -> Set<String> {
    let small: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    let multipliers: [String: Int] = ["hundred": 100, "thousand": 1000, "million": 1_000_000]

    var values: Set<String> = []
    var current = 0
    var running = 0
    var inNumber = false
    func flush() {
        if inNumber { values.insert(String(running + current)) }
        current = 0
        running = 0
        inNumber = false
    }
    let words = text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
    for word in words {
        if let value = small[word] {
            values.insert(String(value))  // "twenty" alone is also a fact
            current += value
            inNumber = true
        } else if let multiplier = multipliers[word], inNumber {
            if multiplier == 100 {
                current = max(current, 1) * 100
            } else {
                running += max(current, 1) * multiplier
                current = 0
            }
            values.insert(String(running + current))
        } else if word != "and" || !inNumber {
            flush()
        }
    }
    flush()
    return values
}

let stopwords: Set<String> = [
    "the", "and", "for", "with", "that", "this", "will", "from", "was", "were",
    "has", "have", "been", "are", "not", "but", "its", "his", "her", "their",
]

func contentWords(_ text: String) -> Set<String> {
    Set(
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 && !stopwords.contains($0) }
            // Fold trivial inflections so "moves" matches "move".
            .map { $0.hasSuffix("s") && !$0.hasSuffix("ss") ? String($0.dropLast()) : $0 }
    )
}

func evaluate(name: String, dir: URL, enhancer: some NoteEnhancer) async throws -> CaseResult {
    let decoder = JSONDecoder()
    let transcript = try decoder.decode(
        Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json"))
    )
    let notes = (try? String(contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
    let expectations = (try? decoder.decode(
        Expectations.self, from: Data(contentsOf: dir.appendingPathComponent("expectations.json"))
    )) ?? Expectations()

    let started = Date.now
    let result = try await enhancer.enhance(rawNotes: notes, transcript: transcript)
    let seconds = Date.now.timeIntervalSince(started)
    let output = result.notes
    let lowered = output.lowercased()

    // Subtitle: generated, non-empty, short enough for a list row, and free
    // of the same meta-narration phrases the notes are checked for.
    let subtitleOK: Bool
    if let subtitle = result.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
        let loweredSubtitle = subtitle.lowercased()
        subtitleOK = subtitle.count <= 120 && !metaPhrases.contains { loweredSubtitle.contains($0) }
    } else {
        subtitleOK = false
    }

    let noteLines = notes
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*")) }
        .filter { !$0.isEmpty }
    var structureOK: Bool?
    if !noteLines.isEmpty {
        // The rewritten notes are the first section, one "- " bullet per line.
        let firstSection = output.components(separatedBy: "\n\n").first ?? ""
        let bullets = firstSection
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("- ") }
        structureOK = bullets.count == noteLines.count
    }

    // Commas out of the haystack so "1,000" matches an expected "1000".
    let haystack = lowered.replacingOccurrences(of: ",", with: "")
    let mustContain = expectations.mustContain ?? []
    let recallHits = mustContain.filter {
        haystack.contains($0.lowercased().replacingOccurrences(of: ",", with: ""))
    }.count

    let banned = metaPhrases + (expectations.mustNotContain ?? []).map { $0.lowercased() }
    let metaOK = !banned.contains { lowered.contains($0) }

    let sourceText = transcript.fullText + " " + notes
    let sourceNumbers = numberTokens(in: sourceText).union(wordNumberValues(in: sourceText))
    let outputNumbers = numberTokens(in: output)
    let numbersOK = outputNumbers.allSatisfy { sourceNumbers.contains($0) }

    // Redundancy: an "Also discussed" bullet that mostly restates a notes
    // bullet is wasted space the reader scans twice.
    var duplicateExtras = 0
    let sections = output.components(separatedBy: "## Also discussed")
    if sections.count == 2 {
        let noteBullets = sections[0]
            .components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
            .map(contentWords)
        let extraBullets = sections[1]
            .components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
        for extra in extraBullets {
            let words = contentWords(extra)
            guard !words.isEmpty else { continue }
            let maxContainment = noteBullets
                .map { Double(words.intersection($0).count) / Double(words.count) }
                .max() ?? 0
            if maxContainment >= 0.7 { duplicateExtras += 1 }
        }
    }

    return CaseResult(
        name: name, structureOK: structureOK,
        recallHits: recallHits, recallTotal: mustContain.count,
        metaOK: metaOK, numbersOK: numbersOK, subtitleOK: subtitleOK,
        duplicateExtras: duplicateExtras,
        seconds: seconds, output: output
    )
}

func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
var runs = 1
if let index = arguments.firstIndex(of: "--runs"), index + 1 < arguments.count {
    runs = Int(arguments[index + 1]) ?? 1
    arguments.removeSubrange(index...(index + 1))
}
let showOutput = arguments.contains("--show")
arguments.removeAll { $0 == "--show" }
let jsonOutput = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

let fixturesDir = URL(fileURLWithPath: arguments.first ?? "../../Fixtures/enhance")
guard FileManager.default.fileExists(atPath: fixturesDir.path) else {
    print("fixtures directory not found: \(fixturesDir.path)")
    exit(66)
}

let enhancer = FoundationModelEnhancer()
guard enhancer.isAvailable else {
    print("Apple Intelligence unavailable on this Mac — cannot run the eval")
    exit(69)
}

let caseDirs = try FileManager.default
    .contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: [.isDirectoryKey])
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var failures = 0
var caseSummaries: [CaseSummary] = []
for run in 1...runs {
    if runs > 1 { print("— run \(run)/\(runs)") }
    for dir in caseDirs {
        let name = dir.lastPathComponent
        do {
            let result = try await evaluate(name: name, dir: dir, enhancer: enhancer)
            let structure = result.structureOK.map { "structure \(mark($0))" } ?? "structure —"
            let line = String(
                format: "%-18s %@  recall %d/%d  meta %@  numbers %@  subtitle %@  dupes %d  (%.1fs)",
                (name as NSString).utf8String!, structure,
                result.recallHits, result.recallTotal,
                mark(result.metaOK), mark(result.numbersOK), mark(result.subtitleOK),
                result.duplicateExtras,
                result.seconds
            )
            print(line)
            if showOutput {
                print(result.output.components(separatedBy: .newlines).map { "    " + $0 }.joined(separator: "\n"))
            }
            let recallOK = result.recallHits >= result.recallTotal
            if result.structureOK == false || !recallOK
                || !result.metaOK || !result.numbersOK || !result.subtitleOK
                || result.duplicateExtras > 0 {
                failures += 1
            }
            caseSummaries.append(CaseSummary(
                name: name, structure: result.structureOK, recall: recallOK,
                meta: result.metaOK, numbers: result.numbersOK, subtitle: result.subtitleOK
            ))
        } catch {
            print("\(name): FAILED — \(error)")
            failures += 1
            caseSummaries.append(CaseSummary(name: name, structure: nil, recall: false, meta: false, numbers: false, subtitle: false))
        }
    }
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) case-run(s) with misses")
if jsonOutput {
    printJSON(EvalResult(ok: failures == 0, cases: caseSummaries))
}
