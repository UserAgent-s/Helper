import Foundation

public enum TextChange: Sendable, Equatable {
    case none
    case append(offset: Int, text: String)
    case replace(text: String)
}

public struct DeltaDiffer: Sendable {
    public private(set) var sent: String = ""

    public init() {}

    public mutating func update(_ text: String) -> TextChange {
        let previous = sent.utf16
        let next = text.utf16
        if next.elementsEqual(previous) {
            return .none
        }
        sent = text
        if next.starts(with: previous), let suffix = String(next.dropFirst(previous.count)) {
            return .append(offset: previous.count, text: suffix)
        }
        return .replace(text: text)
    }

    public mutating func reset() {
        sent = ""
    }
}
