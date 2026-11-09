import Foundation

public enum WireTextSanitizer {
    public static let markerOpen: Character = "⟦"
    public static let markerClose: Character = "⟧"

    public static func sanitize(_ text: String, isFinal: Bool) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == markerOpen else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            while cursor < text.endIndex, isMarkerBody(text[cursor]) {
                cursor = text.index(after: cursor)
            }
            if cursor < text.endIndex, text[cursor] == markerClose, cursor > text.index(after: index) {
                index = text.index(after: cursor)
                continue
            }
            if cursor == text.endIndex, !isFinal {
                break
            }
            output.append(character)
            index = text.index(after: index)
        }
        return isFinal ? emptyIfBlank(output) : output
    }

    private static func isMarkerBody(_ character: Character) -> Bool {
        character == "_" || ("A"..."Z").contains(character) || ("0"..."9").contains(character)
    }

    private static func emptyIfBlank(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }
}
