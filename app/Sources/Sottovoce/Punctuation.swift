import Foundation

/// Applies the punctuation setting to transcription results. The model already outputs full punctuation,
/// so "smart" leaves it as is.
enum Punctuation {
    /// Trailing punctuation that may be dropped (Chinese and Latin)
    private static let trailing = CharacterSet(charactersIn: "。．.！!？?，,、；;：:…")
    /// Punctuation that already ends a sentence
    private static let terminal = CharacterSet(charactersIn: "。．.！!？?…")

    static func apply(_ raw: String, mode: PunctuationMode) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }
        switch mode {
        case .smart:
            return text
        case .full:
            if let last = text.unicodeScalars.last, terminal.contains(last) { return text }
            return text + (isMostlyLatin(text) ? "." : "。")
        case .dropTrailing:
            var s = Substring(text)
            while let last = s.unicodeScalars.last, trailing.contains(last) {
                s = s.dropLast()
            }
            return String(s)
        case .spaces:
            // Replace all punctuation with spaces, then collapse runs of spaces; keep apostrophes in English contractions
            var out = ""
            for ch in text {
                if ch != "'" && ch.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                    out.append(" ")
                } else {
                    out.append(ch)
                }
            }
            return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
    }

    /// Mostly-Latin sentences end with an ASCII period
    private static func isMostlyLatin(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let latin = letters.filter { $0.isASCII }.count
        return latin * 2 > letters.count
    }
}
