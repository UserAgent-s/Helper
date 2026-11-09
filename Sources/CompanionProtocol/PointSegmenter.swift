import Foundation

public enum PointSegmenter {
    public static func segment(_ text: String, answerId: String, isFinal: Bool) -> [AnswerPoint] {
        var ranges: [(start: Int, end: Int)] = []
        var current: (start: Int, end: Int, isList: Bool)?
        var inFence = false
        var previousBlank = false
        var offset = 0

        for line in lines(of: text) {
            let lineStart = offset
            offset += line.length + line.terminator
            let content = line.text
            let trimmed = content.drop { $0 == " " || $0 == "\t" }
            let indent = content.count - trimmed.count
            let isBlank = trimmed.isEmpty
            let lineEnd = lineStart + line.length
            let afterBlank = previousBlank
            previousBlank = isBlank && !inFence

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if current == nil {
                    current = (lineStart, lineEnd, false)
                } else {
                    current?.end = lineEnd
                }
                inFence.toggle()
                continue
            }
            if inFence {
                if !isBlank { current?.end = lineEnd }
                continue
            }
            if isBlank {
                if let block = current, !block.isList {
                    ranges.append((block.start, block.end))
                    current = nil
                }
                continue
            }
            let startsItem = indent < 2 && isListItem(trimmed)
            let startsHeading = indent < 2 && trimmed.hasPrefix("#")
            if startsItem || startsHeading {
                if let block = current { ranges.append((block.start, block.end)) }
                current = (lineStart, lineEnd, startsItem)
                continue
            }
            if let block = current {
                if block.isList, indent == 0, afterBlank {
                    ranges.append((block.start, block.end))
                    current = (lineStart, lineEnd, false)
                } else {
                    current?.end = lineEnd
                }
            } else {
                current = (lineStart, lineEnd, false)
            }
        }
        if let block = current { ranges.append((block.start, block.end)) }

        return ranges.enumerated().map { index, range in
            AnswerPoint(
                pointId: "\(answerId).\(index)",
                index: index,
                start: range.start,
                end: range.end,
                open: !isFinal && index == ranges.count - 1
            )
        }
    }

    static func isListItem(_ line: Substring) -> Bool {
        if let first = line.first, first == "-" || first == "*" || first == "+" {
            let rest = line.dropFirst()
            return rest.first == " " || rest.first == "\t"
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        let after = rest.dropFirst()
        return after.first == " " || after.first == "\t"
    }

    private struct Line {
        let text: Substring
        let length: Int
        let terminator: Int
    }

    private static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" || text[index] == "\r\n" {
                let slice = text[start..<index]
                result.append(Line(text: slice, length: slice.utf16.count, terminator: String(text[index]).utf16.count))
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex {
            let slice = text[start...]
            result.append(Line(text: slice, length: slice.utf16.count, terminator: 0))
        }
        return result
    }
}
