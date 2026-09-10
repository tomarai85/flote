import Foundation

// MARK: - AI provider contract (S1, plan: goal-loop-sleepy-castle.md)
//
// Unifies BOTH AI operations (organize + classify) over interchangeable
// backends so no feature silently breaks when a backend is unavailable
// (Codex risk #3: classify was Claude-only and would have died with the
// key removal). Providers are tried in a fixed order by OrganizeService:
//
//     Apple Foundation Models (macOS 26+, zero download, on-device)
//   → bundled local model      (all Macs, one-time download, on-device)
//   → Claude                   (optional, user-supplied key only)
//
// The contract intentionally returns the SAME organized-markdown string the
// legacy pipeline produced (## タイトル / ## 要点 / ## チェックボックス …) so the
// entire downstream — NoteView.extractTitle, RichTextStorage rendering,
// undo/revert — is untouched by the backend swap. Structured-output
// providers (Foundation Models) render their typed result into this format.

/// Structured result every provider ultimately produces. Text-based
/// providers may parse model markdown into this; structured providers
/// (Foundation Models guided generation) get it natively.
struct OrganizedNoteResult {
    var title: String
    var bullets: [String]
    var checkboxes: [String]

    /// Mechanical cleanup applied to EVERY provider's output (small models
    /// ignore "重複させない" instructions): drop bullets that duplicate a
    /// checkbox item (normalized compare), trim empties. Deterministic —
    /// prompt-tuning alone proved unreliable on the 2026-07-10 probe set.
    func deduplicated() -> OrganizedNoteResult {
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "[。、．，.,!！?？\\s]", with: "", options: .regularExpression)
        }
        let checkboxKeys = Set(checkboxes.map(norm))
        let cleanedBullets = bullets.filter { !checkboxKeys.contains(norm($0)) }
        return OrganizedNoteResult(title: title, bullets: cleanedBullets, checkboxes: checkboxes)
    }

    /// Sanitize a model title: guided generation on thin input sometimes
    /// echoes the SCHEMA TYPE NAME as the title (observed live 2026-07-10:
    /// "FMOrganizedNote" shown to Tom as his note title). Reject leaked /
    /// empty titles and fall back to real content.
    func sanitizedTitle(input: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaked = t.range(of: "organizednote|organized_note|fmorganized|タイトル|^title$",
                             options: [.regularExpression, .caseInsensitive]) != nil
        if !t.isEmpty && !leaked { return t }
        let fallback = bullets.first ?? checkboxes.first
            ?? input.split(separator: "\n").first.map(String.init) ?? input
        return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
    }

    /// Render the note BODY the user actually reads. No "## タイトル"
    /// scaffolding (Tom saw the raw headers in the note — the mock shows a
    /// clean title line + items). NoteView.firstContentLine picks line 1 as
    /// the rolled title; legacy cloud output keeps its own ## format and the
    /// existing extractTitle path handles it unchanged.
    func renderMarkdown() -> String {
        var out = title
        if !bullets.isEmpty {
            out += "\n\n" + bullets.map { "- \($0)" }.joined(separator: "\n")
        }
        if !checkboxes.isEmpty {
            out += "\n\n" + checkboxes.map { "[ ] \($0)" }.joined(separator: "\n")
        }
        return out + "\n"
    }
}

/// Why a provider can't run right now. Surfaced (never swallowed) so the
/// router can fall through and Settings can show an honest status line.
enum AIProviderUnavailableReason: CustomStringConvertible {
    case osTooOld                 // FoundationModels needs macOS 26+
    case appleIntelligenceOff     // device eligible but AI toggle disabled
    case deviceNotEligible        // e.g. Intel Mac for Apple FM
    case modelNotDownloaded       // bundled local model not fetched yet
    case modelNotReady            // OS still preparing the system model
    case missingAPIKey            // Claude tier without a user key
    case unsupportedOperation     // provider can't do this op (e.g. classify)

    var description: String {
        switch self {
        case .osTooOld:             return LN("macOS 26 以降が必要です", "Requires macOS 26 or later")
        case .appleIntelligenceOff: return LN("Apple Intelligence が無効です", "Apple Intelligence is off")
        case .deviceNotEligible:    return LN("この Mac では利用できません", "Not available on this Mac")
        case .modelNotDownloaded:   return LN("ローカルモデルが未ダウンロードです", "Local model not downloaded")
        case .modelNotReady:        return LN("モデルを準備中です", "Preparing the model")
        case .missingAPIKey:        return LN("API キーが未設定です", "No API key set")
        case .unsupportedOperation: return LN("この操作には対応していません", "Operation not supported")
        }
    }
}

enum AIProviderAvailability {
    case available
    case unavailable(AIProviderUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// One AI backend. Implementations must be side-effect free on failure:
/// throw and let the router fall through to the next provider.
protocol AIProvider {
    /// Stable identifier for logging / Settings display.
    var id: String { get }
    /// Human-readable name shown in Settings (JP-first UI).
    var displayName: String { get }
    /// Fully on-device? (drives the "on-device" badge next to Organize.)
    var isOnDevice: Bool { get }

    /// Cheap, non-blocking availability probe. Called before every attempt —
    /// state can change at runtime (model download finishes, AI toggled on).
    func availability() async -> AIProviderAvailability

    /// Restructure a scribble. Returns organized markdown (see file header).
    /// `text` is the pre-sanitized note text (caller handles truncation and
    /// tag-neutralization exactly as the legacy path did).
    func organize(text: String) async throws -> String

    /// Classify a note into an existing group / new group / inbox.
    /// Providers that cannot classify throw
    /// `AIProviderError.unavailable(.unsupportedOperation)` — the router
    /// falls through; it must never silently no-op (Codex risk #3).
    func classify(text: String,
                  existingGroups: [(id: UUID, name: String)],
                  fewShot: String) async throws -> OrganizeService.ClassifyResult

    /// S6 verb menu: apply ONE targeted transformation (チェックリスト化 /
    /// 誤字を直す / 短くする / 英語⇄日本語) and return ONLY the transformed
    /// plain text. Unlike organize() there is no structural contract on the
    /// output — the instruction defines the shape. Fail-closed: an empty
    /// result must throw, never return "" (the caller applies the result
    /// through the same snapshot mechanism as Organize, so a thrown error
    /// leaves the note untouched — content-protection principle).
    func transform(text: String, instruction: String) async throws -> String
}

extension AIProvider {
    /// Default: not supported — the router falls through to the next
    /// backend (mirrors the classify() fall-through contract). Both shipped
    /// providers override this; the default exists so a future provider
    /// that can't transform degrades visibly instead of breaking the build.
    func transform(text: String, instruction: String) async throws -> String {
        throw AIProviderError.unavailable(.unsupportedOperation)
    }
}

enum AIProviderError: LocalizedError {
    case unavailable(AIProviderUnavailableReason)
    case generationFailed(String)
    case guardrailRefusal          // Apple FM safety guardrail fired
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unavailable(let r):      return r.description
        case .generationFailed(let m): return LN("生成に失敗しました", "Generation failed") + "（\(m)）"
        case .guardrailRefusal:        return LN("このノートは端末内 AI が処理を拒否しました", "The on-device AI declined this note")
        case .emptyResult:             return LN("AI の応答が空でした", "The AI returned nothing")
        }
    }
}
