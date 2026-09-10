import Foundation

// MARK: - Bundled local model provider (S1b, spec: .harness/spec-bundled-local-model-2026-07-10.md)
//
// The reliability backbone of Flote's zero-setup AI: a small on-device
// model (Qwen2.5-1.5B-Instruct, 4-bit MLX, Apache-2.0, ~880 MB) downloaded
// once on first use into the app's sandbox container. Unlike Apple
// Foundation Models it has no OS/device/toggle gating and no system
// guardrail that can start refusing at runtime (observed 2026-07-10:
// Apple FM failing machine-wide with SensitiveContentAnalysisML errors
// while availability still reported .available — this provider is the
// fall-through that keeps Organize alive).
//
// PLATFORM: Apple Silicon only (MLX has no x86_64 backend — spec §5).
// All MLX references are compile-gated behind `#if arch(arm64)`; on Intel
// the factory returns nil and the router shows the BYO-key path instead.
//
// DOWNLOAD + LOAD are one call: the id-based `loadModelContainer` overload
// (mlx-swift-lm 3.x) downloads via `#hubDownloader(HubClient)` into our
// fixed cache directory with progress, then loads. The readiness sentinel
// is written only after a load succeeds — the strongest verification there
// is (the model actually loaded), fail-closed by construction.

/// Ungated factory, mirroring FoundationModelsProviderFactory.
enum BundledLocalProviderFactory {
    static func make() -> AIProvider? {
        #if arch(arm64)
        return BundledLocalProvider()
        #else
        return nil
        #endif
    }
}

// MARK: - Transform post-processing (S6c pure core)

// S6C-STRIP-PURE-BEGIN
/// Strips the announcement noise small local models prepend to verb-transform
/// output despite the instructions ("以下が変換結果です:", "Here is the
/// transformed text:", …) plus wrapping code fences. Foundation-only and
/// arch-ungated — the standalone harness (`.harness/tests/s6c-strip-test.sh`)
/// extracts this region with sed and compiles it directly, so the test always
/// runs against the SHIPPING logic. Fail-closed contract: the CALLER must
/// treat an empty result as an error (a stripped-to-nothing reply must never
/// blank the note — content-protection principle).
enum TransformPostProcess {

    /// Leading lines that are announcement, not content. Anchored and
    /// bounded (≤30 chars after the opener, optional colon) so a real
    /// content line that merely STARTS with 以下/こちら etc. survives.
    private static let preamblePattern =
        "^(以下|変換後|こちら|Here is|The transformed|Sure).{0,30}[:：]?$"

    private static func isPreambleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(
            of: preamblePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// A ``` fence line; an opening fence may carry a bare language tag.
    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return false }
        return trimmed.dropFirst(3).allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
    }

    /// Remove leading preamble lines (with surrounding blank lines) and a
    /// wrapping code fence. Runs to a fixpoint (bounded) so stacked noise
    /// like preamble → blank → fence unwraps fully. May return "" — see
    /// the fail-closed contract above.
    static func stripPreamble(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        var changed = true
        var passes = 0
        while changed, passes < 4 {
            changed = false
            passes += 1
            // Leading blank lines.
            while let first = lines.first,
                  first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst(); changed = true
            }
            // Leading announcement lines (blanks they leave behind are
            // swept by the next pass).
            while let first = lines.first, isPreambleLine(first) {
                lines.removeFirst(); changed = true
            }
            // Trailing blank lines.
            while let last = lines.last,
                  last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast(); changed = true
            }
            // Wrapping fence: strip the opener at the head; strip the
            // closer at the tail only if present (a truncated generation
            // may never close its fence).
            if let first = lines.first, isFenceLine(first) {
                lines.removeFirst(); changed = true
                if let last = lines.last,
                   last.trimmingCharacters(in: .whitespaces) == "```" {
                    lines.removeLast()
                }
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
// S6C-STRIP-PURE-END

/// Model download/readiness state, observable by Settings/onboarding UI.
@MainActor
@Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)   // 0.0–1.0
        case ready
        case failed(String)
    }

    private(set) var state: State = .notDownloaded

    /// HF repo pinned by the spec (Apache-2.0 — the 1.5B; the 3B sibling is
    /// NOT Apache, never swap sizes without re-checking license).
    static let repoID = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    nonisolated static let sentinelName = ".flote-model-ready"

    /// Download base inside the sandbox container. HubClient lays the repo
    /// out beneath this; the sentinel sits directly in it.
    nonisolated static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flote", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static var sentinelURL: URL {
        modelsRoot.appendingPathComponent(sentinelName)
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private init() {
        state = Self.readyOnDisk() ? .ready : .notDownloaded
    }

    /// Sentinel = a previous session completed download AND load once.
    nonisolated static func readyOnDisk() -> Bool {
        FileManager.default.fileExists(atPath: sentinelURL.path)
    }

    nonisolated static func markReadyOnDisk() {
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sentinelURL.path, contents: Data())
    }

    func setState(_ new: State) { state = new }

    /// In-flight download+load task; kept so the user can cancel.
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    func rememberDownloadTask(_ task: Task<Void, Never>?) { downloadTask = task }

    /// Best-effort cancel: Task cancellation propagates into the hub
    /// download loop (checked at chunk boundaries — an in-flight chunk
    /// finishes first). loadIfNeeded's catch path cleans partial files and
    /// resets state, so the UI never sticks in .downloading.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Download + unpack headroom for the ~880 MB 4-bit weights.
    nonisolated static let requiredFreeBytes: Int64 = 2_500_000_000

    /// Free space on the volume holding Application Support (the models
    /// live there), via the importance-aware capacity key (counts
    /// purgeable space the system would free for us).
    nonisolated static func availableDiskBytes() -> Int64? {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? support.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Remove partial download data after a failed/cancelled FIRST run so
    /// stale fragments never break the next attempt. Refuses to touch any
    /// path that is not exactly our own …/Flote/Models directory.
    nonisolated static func removePartialModelData() {
        let root = modelsRoot
        guard root.pathComponents.suffix(2) == ["Flote", "Models"] else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Remove the downloaded model (Settings "削除" — ~1 GB is user-visible
    /// disk weight). On arm64 deletion is routed through the engine actor so
    /// it SERIALIZES behind any in-flight download/load (Codex S1 #2: a
    /// naive delete raced loadIfNeeded, which could re-write the sentinel
    /// and flip state back to .ready after the user clicked delete).
    func deleteModel() {
        #if arch(arm64)
        Task.detached(priority: .utility) {
            await BundledLocalEngine.shared.deleteModel()
        }
        #else
        try? FileManager.default.removeItem(at: Self.modelsRoot)
        state = .notDownloaded
        #endif
    }
}

#if arch(arm64)
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers // the #huggingFaceTokenizerLoader macro expands to Tokenizers.* references

/// Owns the loaded model off the main actor and serializes generation
/// (one in-flight request at a time — spec §6 memory guardrail).
actor BundledLocalEngine {
    static let shared = BundledLocalEngine()

    private var container: ModelContainer?

    /// Download (first run, with progress) + load. Sentinel written only
    /// after success. Subsequent calls hit the local cache and just load.
    func loadIfNeeded() async throws {
        guard container == nil else { return }
        // Spec §6: cap the GPU buffer cache well below default so a 1.5B
        // generation stays polite on 8 GB machines.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        try FileManager.default.createDirectory(
            at: LocalModelStore.modelsRoot, withIntermediateDirectories: true
        )
        let firstRun = !LocalModelStore.readyOnDisk()
        if firstRun {
            await MainActor.run { LocalModelStore.shared.setState(.downloading(progress: 0)) }
        }
        do {
            let hub = HubClient(cache: HubCache(location: .fixed(directory: LocalModelStore.modelsRoot)))
            container = try await loadModelContainer(
                from: #hubDownloader(hub),
                using: #huggingFaceTokenizerLoader(),
                id: LocalModelStore.repoID,
                progressHandler: { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = LocalModelStore.shared.state {
                            LocalModelStore.shared.setState(.downloading(progress: fraction))
                        }
                    }
                }
            )
            LocalModelStore.markReadyOnDisk()
            await MainActor.run { LocalModelStore.shared.setState(.ready) }
        } catch {
            // Self-healing sentinel (Codex S1 #4): if a sentinel-backed load
            // fails (cache corrupted/deleted underneath a stale sentinel),
            // remove the sentinel so availability() stops reporting ready
            // and the UI offers re-download instead of silently failing.
            if firstRun {
                // A failed/cancelled first download leaves partial files
                // that can break the next attempt — wipe our models dir
                // (strictly scoped inside removePartialModelData).
                LocalModelStore.removePartialModelData()
            } else {
                try? FileManager.default.removeItem(at: LocalModelStore.sentinelURL)
            }
            let cancelled = error is CancellationError || Task.isCancelled
            await MainActor.run {
                // User cancel is not a failure — return to the download
                // offer instead of showing an error.
                LocalModelStore.shared.setState(
                    cancelled ? .notDownloaded : .failed(error.localizedDescription))
            }
            throw error
        }
    }

    /// Drop the container (memory pressure / model deletion).
    func unload() {
        container = nil
    }

    /// Serialized deletion: runs AFTER any in-flight loadIfNeeded on this
    /// actor, so the final state is always unloaded + files gone (#2).
    func deleteModel() async {
        container = nil
        try? FileManager.default.removeItem(at: LocalModelStore.modelsRoot)
        await MainActor.run { LocalModelStore.shared.setState(.notDownloaded) }
    }

    /// One-shot generation with a fresh session (no chat history wanted).
    func generate(instructions: String, prompt: String, maxTokens: Int = 512) async throws -> String {
        try await loadIfNeeded()
        guard let container else {
            throw AIProviderError.unavailable(.modelNotDownloaded)
        }
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3)
        )
        return try await session.respond(to: prompt)
    }
}

final class BundledLocalProvider: AIProvider {
    let id = "bundled-local"
    let displayName = "内蔵ローカル AI（Qwen 2.5）"
    let isOnDevice = true

    /// Available once the model has been fetched+loaded at least once.
    /// Before that the router skips it — download is user-initiated from
    /// onboarding/Settings (never a surprise 1 GB fetch mid-Organize).
    func availability() async -> AIProviderAvailability {
        LocalModelStore.readyOnDisk()
            ? .available
            : .unavailable(.modelNotDownloaded)
    }

    // MARK: Organize

    /// A 1.5B model drifts on loose instructions, so the contract is a
    /// strict JSON schema, parsed fail-closed with one retry (spec §4) —
    /// malformed output must never destructively replace the note
    /// (content-protection principle).
    private static let organizeInstructions = """
    あなたはユーザーの走り書きを整理するアシスタントです。必ず次の JSON だけを出力してください。説明文・コードフェンス・前置きは禁止です。
    {"title": "短いタイトル(10文字前後)", "bullets": ["要点1", "要点2"], "checkboxes": ["行動項目1"]}
    ルール:
    - ユーザー自身の言葉を保つ。書き直しではなく整形。
    - 入力にある全ての項目を漏らさず反映する。事実・時制を変えない。
    - 入力に無い情報・予定・行動を発明しない。入力が短ければ出力も短く。
    - 行動項目（やることが明確なもの）だけを checkboxes に。それ以外は bullets に。
    - 入力と同じ言語で出力する。
    """

    private struct LocalOrganizedJSON: Decodable {
        var title: String
        var bullets: [String]?
        var checkboxes: [String]?
    }

    func organize(text: String) async throws -> String {
        let raw1 = try await BundledLocalEngine.shared.generate(
            instructions: Self.organizeInstructions,
            prompt: "次の走り書きを整理して: \(text)"
        )
        if var result = Self.parseOrganized(raw1) {
            result.title = result.sanitizedTitle(input: text)
            return result.deduplicated().renderMarkdown()
        }
        // One retry with an explicit parse-failure nudge (spec §4).
        let raw2 = try await BundledLocalEngine.shared.generate(
            instructions: Self.organizeInstructions,
            prompt: "出力が JSON ではありませんでした。JSON だけを出力してください。次の走り書きを整理して: \(text)"
        )
        if var result = Self.parseOrganized(raw2) {
            result.title = result.sanitizedTitle(input: text)
            return result.deduplicated().renderMarkdown()
        }
        throw AIProviderError.generationFailed("ローカルモデルの出力を解析できませんでした")
    }

    /// Tolerant JSON extraction: take the outermost object, decode.
    /// Returns nil (never a mangled note) on failure.
    static func parseOrganized(_ raw: String) -> OrganizedNoteResult? {
        guard let jsonRange = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) else {
            return nil
        }
        guard let data = String(raw[jsonRange]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalOrganizedJSON.self, from: data) else {
            return nil
        }
        let title = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bullets = (decoded.bullets ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let checkboxes = (decoded.checkboxes ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !title.isEmpty || !bullets.isEmpty || !checkboxes.isEmpty else { return nil }
        return OrganizedNoteResult(title: title, bullets: bullets, checkboxes: checkboxes)
    }

    // MARK: Transform (S6 verb menu)

    /// Same engine as organize but plain text out — the verb instruction
    /// defines the output shape, so no JSON contract here. Fail-closed: an
    /// empty generation throws instead of returning "" (a verb result must
    /// never silently blank the note — content-protection principle).
    func transform(text: String, instruction: String) async throws -> String {
        let instructions = """
        あなたはテキスト変換アシスタントです。指示に従ってテキストを変換し、変換後のテキストだけを出力してください。説明・前置き・コードフェンスは禁止。入力に無い情報・項目を発明しない。固有名詞・数値・日時・URL は保持する。
        指示: \(instruction)
        """
        let raw = try await BundledLocalEngine.shared.generate(
            instructions: instructions,
            prompt: "次のテキストを変換して:\n\(text)",
            maxTokens: 1500
        )
        // S6c: strip the "以下が変換結果です:"-style preamble + wrapping
        // fences the 1.5B model emits despite the 禁止 instruction. If
        // stripping leaves nothing, throw — never blank the note.
        let out = TransformPostProcess.stripPreamble(raw)
        guard !out.isEmpty else { throw AIProviderError.emptyResult }
        return out
    }

    // MARK: Classify

    private struct LocalClassifyJSON: Decodable {
        var action: String
        var groupName: String?
    }

    func classify(text: String,
                  existingGroups: [(id: UUID, name: String)],
                  fewShot: String) async throws -> OrganizeService.ClassifyResult {
        let groupList = existingGroups.map { "- \($0.name)" }.joined(separator: "\n")
        let instructions = """
        あなたはメモをグループに仕分けます。必ず次の JSON だけを出力してください。
        {"action": "existing | new | inbox", "groupName": "対象グループ名(inboxなら空)"}
        - 既存グループに明確に合うなら existing とそのグループ名。
        - 明確なテーマがあるが既存に無いなら new と短い新グループ名。
        - 曖昧なら inbox。
        既存グループ:
        \(groupList.isEmpty ? "(なし)" : groupList)
        \(fewShot.isEmpty ? "" : "仕分け例:\n\(fewShot)")
        """
        let raw = try await BundledLocalEngine.shared.generate(
            instructions: instructions,
            prompt: "次のメモを仕分けて: \(text)",
            maxTokens: 128
        )
        guard let jsonRange = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
              let data = String(raw[jsonRange]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalClassifyJSON.self, from: data) else {
            return .inbox // fail-safe: never block sorting on parse failure
        }
        let name = (decoded.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch decoded.action.lowercased() {
        case "existing":
            if let match = existingGroups.first(where: { $0.name == name })
                ?? existingGroups.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return .existing(match.id)
            }
            return .inbox
        case "new":
            return name.isEmpty ? .inbox : .newGroup(name: name)
        default:
            return .inbox
        }
    }
}

// MARK: - User-initiated download (onboarding / Settings)

extension LocalModelStore {
    /// Kick off download+load in the background; UI observes `state`.
    func startDownload() {
        if case .downloading = state { return }
        guard !isReady else { return }
        // Fail closed BEFORE spawning: a download that runs the disk dry
        // helps nobody. Unknown capacity (nil) is allowed through — the
        // download itself will surface a real write error if space runs out.
        if let free = Self.availableDiskBytes(), free < Self.requiredFreeBytes {
            let needGB = Double(Self.requiredFreeBytes) / 1_000_000_000
            setState(.failed(String(
                format: "ディスクの空き容量が不足しています（約 %.1f GB の空きが必要です）", needGB)))
            return
        }
        let task = Task.detached(priority: .utility) {
            do {
                try await BundledLocalEngine.shared.loadIfNeeded()
            } catch {
                // State already handled inside loadIfNeeded.
            }
        }
        rememberDownloadTask(task)
    }
}
#endif
