import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Apple's own translator, on the device: free, offline and nearly instant (five long paragraphs in about a second
/// and a half, tested 2026-11-24), and as good as a careful human translation. Used where a plain, fluent
/// translation is all that is needed: the "Native" level and the side column in your own language. The graded
/// levels stay with the AI service, as Apple's on-device model can't simplify text reliably.
///
/// Works from iOS 26 (where a translation can be made outside a view) once both languages' packs are on the
/// device; everywhere else it reports itself unavailable and the AI service does the work as before.
enum AppleTranslation {
    /// Whether text can be translated from one language to the other on this device right now.
    static func isReady(from source: String, to target: String) async -> Bool {
        guard source != target else { return false }
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                            to: Locale.Language(identifier: target))
            return status == .installed
        }
        #endif
        return false
    }

    /// The translations of `texts`, in order; nil if Apple's translator isn't ready for these languages or fails.
    static func translate(_ texts: [String], from source: String, to target: String) async -> [String]? {
        guard !texts.isEmpty, await isReady(from: source, to: target) else { return nil }
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                             target: Locale.Language(identifier: target))
            var out: [String] = []
            for t in texts {
                guard let r = try? await session.translate(t) else { return nil }
                out.append(r.targetText)
            }
            return out
        }
        #endif
        return nil
    }

    /// What Settings shows: whether the two languages are ready, can be downloaded, or aren't offered.
    enum Status { case ready, downloadable, unavailable }

    static func status(from source: String, to target: String) async -> Status {
        guard source != target else { return .unavailable }
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            switch await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                      to: Locale.Language(identifier: target)) {
            case .installed: return .ready
            case .supported: return .downloadable
            default: return .unavailable
            }
        }
        #endif
        return .unavailable
    }
}

/// Asks iOS to download the translation languages for a pair (iOS shows its own download sheet), then calls `done`.
struct AppleTranslationDownload: ViewModifier {
    @Binding var pair: (source: String, target: String)?
    var done: () -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            content.translationTask(pair.map {
                TranslationSession.Configuration(source: Locale.Language(identifier: $0.source),
                                                 target: Locale.Language(identifier: $0.target))
            }) { session in
                try? await session.prepareTranslation()
                await MainActor.run { pair = nil; done() }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
