import Foundation

// MARK: - Apple Foundation Models provider (S1)
//
// Zero-download on-device backend: the ~3B system model that ships with
// Apple Intelligence, exposed to third-party apps on macOS 26+ via the
// FoundationModels framework. Free, offline, private — the primary
// Organize path when available.
//
// COMPILE GATING (Codex risks #4/#5): the deployment target is macOS 14,
// so everything FoundationModels-related — including the @Generable macro
// types — lives ONLY in this file behind `#if canImport(FoundationModels)`
// + `@available(macOS 26, *)`. Never reference these types from ungated
// files; probe through `FoundationModelsProviderFactory.make()` instead.
//
// RUNTIME GATING: macOS 26 alone is NOT enough — availability also depends
// on device eligibility and the user's Apple Intelligence toggle, so every
// call re-checks `SystemLanguageModel.default.availability`.
//
// Validated on this machine 2026-07-10 (see plan §Context): JP+EN scribbles
// structured correctly, no guardrail refusal on sensitive personal notes.
// The instructions below carry the two fixes from that test: no fabrication
// on thin input, preserve every item without changing tense/facts.

/// Ungated factory: the only symbol ungated code may touch.
/// Returns nil on OSes/SDKs without FoundationModels.
enum FoundationModelsProviderFactory {
    static func make() -> AIProvider? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsProvider()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
final class FoundationModelsProvider: AIProvider {
    let id = "apple-fm"
    let displayName = "Apple Intelligence（この Mac の内蔵 AI）"
    let isOnDevice = true

    // MARK: Structured output types (gated here — see file header)

    @Generable
    fileprivate struct FMOrganizedNote {
        @Guide(description: "短いタイトル。10文字前後。時刻だけのタイトルは禁止")
        var title: String
        @Guide(description: "要点。入力の情報を漏らさず、ユーザー自身の言葉を保った短い箇条書きの配列。行動項目は含めない")
        var bullets: [String]
        @Guide(description: "行動項目（やることが明確なもの）だけの配列。各項目は短い文")
        var checkboxes: [String]
    }

    @Generable
    fileprivate struct FMClassifyChoice {
        @Guide(description: "existing / new / inbox のいずれか1語")
        var action: String
        @Guide(description: "action が existing のとき対象グループ名、new のとき新グループ名。inbox のときは空文字")
        var groupName: String
    }

    // MARK: Availability

    func availability() async -> AIProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:          return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
            case .modelNotReady:              return .unavailable(.modelNotReady)
            @unknown default:                 return .unavailable(.modelNotReady)
            }
        @unknown default:
            return .unavailable(.modelNotReady)
        }
    }

    // MARK: Organize

    /// Carries the two fixes from the 2026-07-10 real-data test:
    /// (1) thin input must not be padded with invented content,
    /// (2) every input item survives, tense/facts unchanged.
    private static let organizeInstructions = """
    あなたはユーザーの走り書きを整理します。以下を厳守してください。
    - ユーザー自身の言葉を保つ。書き直しではなく整形。
    - 入力にある全ての項目を漏らさず反映する。事実・時制・ニュアンスを変えない（例:「送る」を「送っている」に変えない）。
    - 入力に無い情報・予定・行動を発明しない。入力が短い・薄い場合は出力も同じだけ短くする。水増し禁止。
    - 要約して情報を削らない。
    - 行動項目（やることが明確なもの）だけを checkboxes に。それ以外の情報は bullets に。重複させない。
    - 入力と同じ言語で出力する。
    """

    func organize(text: String) async throws -> String {
        guard case .available = await availability() else {
            throw AIProviderError.unavailable(mappedUnavailableReason())
        }
        do {
            let session = LanguageModelSession(instructions: Self.organizeInstructions)
            let response = try await session.respond(
                to: "次の走り書きを整理して: \(text)",
                generating: FMOrganizedNote.self
            )
            let o = response.content
            var result = OrganizedNoteResult(
                title: o.title.trimmingCharacters(in: .whitespacesAndNewlines),
                bullets: o.bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                  .filter { !$0.isEmpty },
                checkboxes: o.checkboxes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty }
            )
            guard !result.title.isEmpty || !result.bullets.isEmpty || !result.checkboxes.isEmpty else {
                throw AIProviderError.emptyResult
            }
            result.title = result.sanitizedTitle(input: text)
            return result.deduplicated().renderMarkdown()
        } catch let e as AIProviderError {
            throw e
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    // MARK: Classify

    func classify(text: String,
                  existingGroups: [(id: UUID, name: String)],
                  fewShot: String) async throws -> OrganizeService.ClassifyResult {
        guard case .available = await availability() else {
            throw AIProviderError.unavailable(mappedUnavailableReason())
        }
        let groupList = existingGroups.map { "- \($0.name)" }.joined(separator: "\n")
        let instructions = """
        あなたはメモを既存グループに仕分けます。
        - 既存グループに明確に合うなら action=existing とそのグループ名。
        - どれにも合わないが明確なテーマがあるなら action=new と短い新グループ名。
        - 判断が曖昧なら action=inbox（無理に仕分けない）。
        既存グループ:
        \(groupList.isEmpty ? "(なし)" : groupList)
        \(fewShot.isEmpty ? "" : "\n過去の仕分け例:\n\(fewShot)")
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "次のメモを仕分けて: \(text)",
                generating: FMClassifyChoice.self
            )
            let choice = response.content
            let name = choice.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            switch choice.action.lowercased() {
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
        } catch let e as AIProviderError {
            throw e
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    // MARK: Transform (S6 verb menu)

    /// Free-form single-instruction transform. Plain-text respond (no
    /// @Generable) — each verb defines its own output shape, so a fixed
    /// schema would fight the instruction instead of helping it.
    func transform(text: String, instruction: String) async throws -> String {
        guard case .available = await availability() else {
            throw AIProviderError.unavailable(mappedUnavailableReason())
        }
        let instructions = """
        あなたはテキスト変換アシスタントです。指示に従ってテキストを変換し、変換後のテキストだけを出力してください。
        - 説明・前置き・後書き・コードフェンス・引用符は一切付けない。
        - 入力に無い情報・項目を発明しない。固有名詞・数値・日時・URL は保持する。
        指示: \(instruction)
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "次のテキストを変換して:\n\(text)")
            let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { throw AIProviderError.emptyResult }
            return out
        } catch let e as AIProviderError {
            throw e
        } catch {
            throw Self.mapGenerationError(error)
        }
    }

    // MARK: Error mapping

    /// The system guardrail cannot be disabled and occasionally over-fires
    /// on innocuous personal notes. Detect it so the router can fall through
    /// to the bundled local model instead of hard-failing the Organize tap.
    /// String-based detection is deliberate: it compiles against any SDK
    /// minor; tighten to typed GenerationError cases once the API surface
    /// is pinned by a passing build on CI.
    private static func mapGenerationError(_ error: Error) -> AIProviderError {
        let desc = String(describing: error)
        if desc.localizedCaseInsensitiveContains("guardrail")
            || desc.localizedCaseInsensitiveContains("refusal") {
            return .guardrailRefusal
        }
        return .generationFailed(error.localizedDescription)
    }

    private func mappedUnavailableReason() -> AIProviderUnavailableReason {
        switch SystemLanguageModel.default.availability {
        case .available: return .modelNotReady // race: became available; caller will retry
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:           return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady:               return .modelNotReady
            @unknown default:                  return .modelNotReady
            }
        @unknown default: return .modelNotReady
        }
    }
}
#endif
