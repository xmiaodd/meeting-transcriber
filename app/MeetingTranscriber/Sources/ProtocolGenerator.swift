import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "ProtocolGenerator")

/// Abstraction for protocol generation, enabling mock injection in tests.
protocol ProtocolGenerating {
    func generate(transcript: String, title: String, diarized: Bool) async throws -> String
}

/// Shared protocol utilities: prompts, file operations, and error types.
enum ProtocolGenerator {
    static let protocolPrompt = """
    You are a professional meeting minute taker.
    Create a structured meeting protocol in {LANGUAGE} from the following transcript.

    Return ONLY the finished Markdown document - no explanations, no introduction,
    no comments before or after.

    Use exactly this structure:

    # Meeting Protocol - [Meeting Title]
    **Date:** [Date from context or today]

    ---

    ## Summary
    [3-5 sentence summary of the meeting]

    ## Participants
    - [Name 1]
    - [Name 2]

    ## Topics Discussed

    ### [Topic 1]
    [What was discussed]

    ### [Topic 2]
    [What was discussed]

    ## Decisions
    - [Decision 1]
    - [Decision 2]

    ## Tasks
    | Task | Responsible | Deadline | Priority |
    |------|-------------|----------|----------|
    | [Description] | [Name] | [Date or open] | 🔴 high / 🟡 medium / 🟢 low |

    ## Open Questions
    - [Question 1]
    - [Question 2]

    Do NOT include the full transcript in the output – it will be appended automatically.

    ---
    Transcript:
    """

    static let diarizationNote = """
    \nNote: The transcript contains speaker labels in brackets. \
    Possible label formats:
    - [SPEAKER_00], [SPEAKER_01] — auto-detected speakers (use Speaker 1, Speaker 2)
    - [Me], [Roman] etc. — the local microphone user
    - [Remote] — remote participant(s) without diarization
    - [Name] — a recognized or named speaker
    Use these labels to identify participants. \
    In the Participants section, list them by name where possible. \
    In the Topics Discussed section, attribute key statements to speakers.
    """

    /// Load the protocol prompt, preferring a custom file over the built-in default.
    ///
    /// Reads `AppPaths.customPromptFile` if it exists and is non-empty,
    /// otherwise falls back to the hardcoded `protocolPrompt`.
    static func applyLanguage(_ prompt: String, language: String) -> String {
        prompt.replacingOccurrences(of: "{LANGUAGE}", with: language)
    }

    /// Load the protocol generation prompt. Reads from `url` (default
    /// `AppPaths.customPromptFile`) when present and non-empty; falls back
    /// to the built-in `protocolPrompt`. The `url` parameter exists so tests
    /// can use unique per-test paths instead of racing on the shared one.
    static func loadPrompt(from url: URL = AppPaths.customPromptFile) -> String {
        if let custom = try? String(contentsOf: url, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("Using custom protocol prompt from \(url.path)")
            return custom
        }
        return protocolPrompt
    }

    /// Build the localized system prompt: `loadPrompt` + `applyLanguage`
    /// + optional `diarizationNote`. Excludes the transcript itself —
    /// callers append or attach it as they see fit.
    static func buildSystemPrompt(diarized: Bool, language: String) -> String {
        var prompt = applyLanguage(loadPrompt(), language: language)
        if diarized { prompt += diarizationNote }
        return prompt
    }

    // MARK: - File Operations

    /// Save a transcript to a text file.
    ///
    /// - Returns: URL of the saved file
    static func saveTranscript(_ text: String, title: String, dir: URL) throws -> URL {
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try ensureWritable(dir)
        let url = dir.appendingPathComponent(filename(title: title, ext: "txt"))
        try write(text, to: url)
        logger.info("Transcript saved: \(url.lastPathComponent)")
        return url
    }

    /// Save a protocol to a Markdown file.
    ///
    /// - Returns: URL of the saved file
    static func saveProtocol(_ markdown: String, title: String, dir: URL) throws -> URL {
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try ensureWritable(dir)
        let url = dir.appendingPathComponent(filename(title: title, ext: "md"))
        try write(markdown, to: url)
        logger.info("Protocol saved: \(url.lastPathComponent)")
        return url
    }

    /// Create `dir` if needed and confirm we can actually write into it.
    ///
    /// `startAccessingSecurityScopedResource()` returns `false` when the
    /// bookmark behind `dir` no longer grants access (the failure mode that
    /// silently killed the pipeline with a bare `NSCocoaErrorDomain 516`).
    /// Surfacing it here gives callers a typed, actionable error instead.
    private static func ensureWritable(_ dir: URL) throws {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ProtocolError.outputDirNotWritable(dir.path)
        }
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw ProtocolError.outputDirNotWritable(dir.path)
        }
    }

    /// Write atomically, translating a sandbox-permission failure into
    /// `outputDirNotWritable` so the pipeline reports the real cause rather
    /// than the raw Cocoa/`EEXIST` errno.
    private static func write(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileWriteNoPermissionError || error.code == 516) {
            throw ProtocolError.outputDirNotWritable(url.deletingLastPathComponent().path)
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmm"
        return fmt
    }()

    /// Sanitize a title into a safe filename slug (path-traversal safe).
    /// Falls back to `"meeting"` if no allowed characters remain.
    private static let slugAllowed = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_"))

    static func sanitizeSlug(_ title: String) -> String {
        let slug = String(stripExistingTimestampPrefix(title)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .unicodeScalars
            .filter { slugAllowed.contains($0) }
            .map(Character.init))
        return slug.isEmpty ? "meeting" : slug
    }

    /// Re-importing a previously-processed recording feeds its slug-based stem
    /// back as a title (e.g. `20260516_1319_20260503_174538`). `filename` would
    /// then prepend ANOTHER `yyyyMMdd_HHmm_` → compounding-prefix loop on every
    /// reprocess. Strip a leading `yyyyMMdd_HHmm[ss]_` so the slug stays
    /// idempotent across reprocesses.
    static func stripExistingTimestampPrefix(_ title: String) -> String {
        let patterns = [#"^\d{8}_\d{6}_"#, #"^\d{8}_\d{4}_"#]
        var result = title
        // Apply repeatedly — input may already contain multiple compounded layers
        // from earlier buggy runs; one call should normalize the worst case.
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = result.range(of: pattern, options: .regularExpression) {
                    result.removeSubrange(range)
                    changed = true
                }
            }
        }
        return result.isEmpty ? title : result
    }

    /// Generate a filename: `{yyyyMMdd_HHmm}_{slug}.{ext}`
    static func filename(title: String, ext: String) -> String {
        let date = filenameFormatter.string(from: Date())
        let slug = sanitizeSlug(title)
        return "\(date)_\(slug).\(ext)"
    }
}

enum ProtocolError: LocalizedError {
    #if !APPSTORE
        case cliNotFound(String)
        case cliFailed(Int, String)
        case timeout
    #endif
    case emptyProtocol
    case httpError(Int, String)
    case connectionFailed(String)
    /// The output directory could not be written to — almost always because the
    /// user-picked folder's security-scoped bookmark no longer grants sandbox
    /// access (folder moved, restored from backup, or the app's TCC grant was
    /// reset). Re-selecting the folder in Settings → Output fixes it.
    case outputDirNotWritable(String)

    var errorDescription: String? {
        switch self {
        #if !APPSTORE
            case let .cliNotFound(bin): "'\(bin)' CLI not found. Install: npm install -g @anthropic-ai/claude-code"

            case let .cliFailed(code, stderr): "Claude CLI exited with code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"

            case .timeout: "Claude CLI took too long (>10 min)"
        #endif

        case .emptyProtocol: "Protocol is empty. Tip: Test manually: echo Hello | claude --print"

        case let .httpError(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"

        case let .connectionFailed(reason): "Connection failed: \(reason)"

        case let .outputDirNotWritable(path):
            "Can't write to output folder (\(path)). Re-select it in Settings → Output to restore access."
        }
    }
}
