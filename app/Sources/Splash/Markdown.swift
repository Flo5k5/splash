import AppKit
import SwiftUI

/// A reply's Markdown, as blocks: the CommonMark and GitHub subset models write. Paragraphs keep
/// their line breaks; lists nest by indentation; a fence left open, as while a reply streams, runs
/// to the end. One pass over the lines with no backtracking, so a streaming reply can parse again
/// on every update.
enum Markdown {
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A final newline ends the last line rather than starting another.
        if lines.last?.isEmpty == true { lines.removeLast() }
        var parser = Parser(lines: lines, depth: 0)
        return parser.blocks()
    }

    /// A span of text with its inline styles. Inline code is set in `code` on a fill, only web and
    /// mail links stay links, and an image shows as a link to it, so a reply never loads a URL by itself.
    static func inline(_ text: String, code: Font = .system(size: 13.5, design: .monospaced)) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for (url, range) in string.runs[\.imageURL] {
            guard let url else { continue }
            string[range].imageURL = nil
            string[range].link = url
        }
        for (url, range) in string.runs[\.link] {
            guard let url, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            string[range].link = nil
        }
        for (intent, range) in string.runs[\.inlinePresentationIntent] where intent?.contains(.code) == true {
            string[range].font = code
            string[range].backgroundColor = Color(nsColor: .tertiarySystemFill)
        }
        return string
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, String)
    /// A fenced block and the first word after its fence.
    case code(language: String?, String)
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    case quote([MarkdownBlock])
    case table(header: [String], rows: [[String]])
    case rule
}

/// Reads blocks from lines whose container (list item or quote) is already taken off.
private struct Parser {
    /// Lists and quotes nest this deep at most; deeper markers stay text.
    static let maximumDepth = 10

    let lines: [Substring]
    let depth: Int
    var index = 0

    mutating func blocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        while index < lines.count {
            let text = lines[index].trimmed
            let found = text.isEmpty ? nil : block(afterText: !paragraph.isEmpty)
            if found != nil || text.isEmpty, !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if let found {
                blocks.append(found)
            } else {
                if !text.isEmpty { paragraph.append(text) }
                index += 1
            }
        }
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        return blocks
    }

    /// The block starting at the current line, its lines read; nil for a line of text.
    private mutating func block(afterText: Bool) -> MarkdownBlock? {
        let line = lines[index]
        let text = Line.indentation(line).text
        if let fence = Fence(line) {
            index += 1
            return code(fence)
        }
        if let heading = Line.heading(text) {
            index += 1
            return heading
        }
        if Line.isRule(text) {
            index += 1
            return .rule
        }
        if depth < Self.maximumDepth {
            if text.first == ">" { return quote() }
            // Text runs on into a list only at a bullet or at 1, so "In\n1984. …" stays text.
            if let item = ListItem(line), !afterText || !item.ordered || item.number == 1 { return list(item) }
        }
        if text.hasPipe, index + 1 < lines.count, lines[index + 1].hasPipe {
            let header = Line.cells(text)
            if Line.isDelimiterRow(lines[index + 1], columns: header.count) { return table(header) }
        }
        return nil
    }

    private mutating func code(_ fence: Fence) -> MarkdownBlock {
        var body: [Substring] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if fence.closes(line) { break }
            body.append(Line.dropIndentation(line, fence.indent))
        }
        return .code(language: fence.language, body.joined(separator: "\n"))
    }

    private mutating func quote() -> MarkdownBlock {
        var inner: [Substring] = []
        while index < lines.count {
            let text = Line.indentation(lines[index]).text
            guard text.first == ">" else { break }
            inner.append(text.dropFirst().first == " " ? text.dropFirst(2) : text.dropFirst())
            index += 1
        }
        var parser = Parser(lines: inner, depth: depth + 1)
        return .quote(parser.blocks())
    }

    /// The list from `first` on. A line is the item's while it is indented past the item's marker
    /// (so a nested list need not reach the item's text) or while a fence in the item is open; a
    /// blank line is the item's when the item goes on after it.
    private mutating func list(_ first: ListItem) -> MarkdownBlock {
        var items: [[MarkdownBlock]] = []
        var item = first
        while true {
            index += 1
            var content = [item.text]
            var fence = Fence(item.text)
            while index < lines.count {
                if fence == nil {
                    let next = lines[index...].firstIndex { !$0.isBlank } ?? lines.count
                    guard next < lines.count, Line.indentation(lines[next]).columns > item.indent else { break }
                    content += repeatElement("", count: next - index)
                    index = next
                }
                let line = Line.dropIndentation(lines[index], item.contentIndent)
                content.append(line)
                if let open = fence {
                    if open.closes(line) { fence = nil }
                } else {
                    fence = Fence(line)
                }
                index += 1
            }
            var parser = Parser(lines: content, depth: depth + 1)
            items.append(parser.blocks())
            guard let next = lines[index...].firstIndex(where: { !$0.isBlank }),
                  let sibling = ListItem(lines[next]), sibling.ordered == first.ordered,
                  !Line.isRule(Line.indentation(lines[next]).text)
            else { break }
            index = next
            item = sibling
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    private mutating func table(_ header: [String]) -> MarkdownBlock {
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].hasPipe {
            let cells = Line.cells(lines[index])
            rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
            index += 1
        }
        return .table(header: header, rows: rows)
    }
}

/// An opening code fence: three or more backticks or tildes.
private struct Fence {
    let marker: Character
    let length: Int
    let indent: Int
    let language: String?

    init?(_ line: Substring) {
        let (indent, text) = Line.indentation(line)
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let length = text.prefix { $0 == marker }.count
        let info = text.dropFirst(length)
        guard length >= 3, marker == "~" || !info.contains("`") else { return nil }
        self.marker = marker
        self.length = length
        self.indent = indent
        language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// Whether `line` closes the fence: the same marker, at least as many, and nothing after.
    func closes(_ line: Substring) -> Bool {
        let text = line.trimmed
        return text.first == marker && text.allSatisfy { $0 == marker } && text.count >= length
    }
}

/// A list item's first line: a bullet (`-`, `*`, `+`) or a number and `.` or `)`, then a space.
private struct ListItem {
    let ordered: Bool
    let number: Int
    /// The columns before the marker.
    let indent: Int
    /// The columns before the item's text, where its later lines start.
    let contentIndent: Int
    let text: Substring

    init?(_ line: Substring) {
        let (indent, text) = Line.indentation(line)
        let width: Int
        if let bullet = text.first, "-*+".contains(bullet) {
            ordered = false
            number = 1
            width = 1
        } else {
            let digits = text.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let number = Int(digits),
                  let delimiter = text.dropFirst(digits.count).first, delimiter == "." || delimiter == ")"
            else { return nil }
            ordered = true
            self.number = number
            width = digits.count + 1
        }
        let rest = text.dropFirst(width)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let (spaces, content) = Line.indentation(rest)
        // Text five or more columns past the marker keeps all but one of them.
        let gap = content.isEmpty || spaces > 4 ? 1 : spaces
        self.indent = indent
        contentIndent = indent + width + gap
        self.text = gap == spaces ? content : Line.dropIndentation(rest, 1)
    }
}

private enum Line {
    /// The columns of a line's indentation, a tab reaching the next multiple of four, and the text after it.
    static func indentation(_ line: Substring) -> (columns: Int, text: Substring) {
        var columns = 0
        var index = line.startIndex
        while index < line.endIndex {
            switch line[index] {
            case " ": columns += 1
            case "\t": columns += 4 - columns % 4
            default: return (columns, line[index...])
            }
            index = line.index(after: index)
        }
        return (columns, line[index...])
    }

    /// The line without up to `columns` columns of its indentation.
    static func dropIndentation(_ line: Substring, _ columns: Int) -> Substring {
        var column = 0
        var index = line.startIndex
        while column < columns, index < line.endIndex {
            switch line[index] {
            case " ": column += 1
            case "\t":
                let stop = column + 4 - column % 4
                // A tab reaching past the cut leaves its remaining columns as spaces.
                if stop > columns { return Substring(String(repeating: " ", count: stop - columns)) + line[line.index(after: index)...] }
                column = stop
            default: return line[index...]
            }
            index = line.index(after: index)
        }
        return line[index...]
    }

    /// An ATX heading: one to six `#`, a space, and the title, less any closing `#`s.
    static func heading(_ text: Substring) -> MarkdownBlock? {
        let level = text.prefix { $0 == "#" }.count
        let rest = text.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmed
        let open = title.dropLast(title.reversed().prefix { $0 == "#" }.count)
        let closed = open.isEmpty || open.last == " " || open.last == "\t"
        return .heading(level: level, String(closed ? open.trimmed : title))
    }

    /// Three or more `-`, `*` or `_`, alone on the line but for spaces.
    static func isRule(_ text: Substring) -> Bool {
        guard let mark = text.first, "-*_".contains(mark) else { return false }
        var count = 0
        for character in text {
            if character == mark {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    /// A table row's cells, split at the pipes not escaped with a backslash; the outer pipes are optional.
    static func cells(_ line: Substring) -> [String] {
        var row = line.trimmed
        if row.first == "|" { row = row.dropFirst() }
        if row.last == "|", !row.dropLast().hasSuffix("\\") { row = row.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in row {
            if character == "|" && !escaped {
                cells.append(Self.cell(cell))
                cell = ""
            } else if character == "|" {
                cell.removeLast()
                cell.append(character)
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(Self.cell(cell))
        return cells
    }

    /// A cell's text, its `<br>`s line breaks as GitHub shows them.
    private static func cell(_ text: String) -> String {
        ["<br>", "<br/>", "<br />"].reduce(String(text[...].trimmed)) { $0.replacing($1, with: "\n") }
    }

    /// A table's delimiter row: a cell of dashes, colons at either end allowed, for each column.
    static func isDelimiterRow(_ line: Substring, columns: Int) -> Bool {
        let cells = cells(line)
        return cells.count == columns && cells.allSatisfy { cell in
            var dashes = cell[...]
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }
}

private extension Substring {
    var trimmed: Substring {
        let start = firstIndex { !$0.isWhitespace } ?? endIndex
        let end = self[start...].lastIndex { !$0.isWhitespace }.map(index(after:)) ?? start
        return self[start..<end]
    }

    var isBlank: Bool { allSatisfy(\.isWhitespace) }

    /// Whether the line has a `|`, as table rows do; checked on every line of text, so by byte.
    var hasPipe: Bool { utf8.contains(UInt8(ascii: "|")) }
}

/// A reply's Markdown, drawn natively in the system fonts and styles: selectable text, code in
/// rounded blocks to copy, tables in a grid. Blocks are keyed by position and redraw only when
/// they change, so a streaming reply redraws its last block alone.
struct MarkdownView: View {
    let text: String

    var body: some View {
        Blocks(blocks: Markdown.blocks(text), depth: 0)
            .font(.reading)
            .textSelection(.enabled)
    }
}

private struct Blocks: View {
    let blocks: [MarkdownBlock]
    /// How many lists these blocks are in.
    let depth: Int
    var spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                BlockView(block: block, depth: depth)
                    .equatable()
                    .padding(.top, index > 0 && block.isHeading ? 6 : 0)
            }
        }
    }
}

private struct BlockView: View, Equatable {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .lineSpacing(5)
        case .heading(let level, let text):
            // A quiet scale over the 15-point reading text.
            let size: CGFloat = level == 1 ? 20 : level == 2 ? 17 : 15
            Text(Markdown.inline(text, code: .system(size: size - 1.5, weight: .semibold, design: .monospaced)))
                .font(.system(size: size, weight: .semibold))
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .list(let ordered, let start, let items):
            ListBlock(ordered: ordered, start: start, items: items, depth: depth)
        case .quote(let blocks):
            Blocks(blocks: blocks, depth: depth)
                .foregroundStyle(.secondary)
                .setApart()
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

private extension MarkdownBlock {
    var isHeading: Bool {
        if case .heading = self { true } else { false }
    }
}

/// Code, outlined: what a reply gives to take away, apart from what is said, which the user's
/// messages show filled. Its language and Copy head it.
private struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                CopyButton(copy: { NSPasteboard.put(code) })
                .buttonStyle(.hover)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Copy")
                .accessibilityLabel("Copy Code")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 32)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
    }
}

extension View {
    /// Set apart from the text around it by a rule at its side, as quotes and the model's thinking
    /// are.
    func setApart() -> some View {
        padding(.leading, 14).overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 2) }
    }
}

private struct ListBlock: View {
    let ordered: Bool
    let start: Int
    let items: [[MarkdownBlock]]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The widest marker sets the column, so the items' text lines up.
                    marker(items.count - 1)
                        .hidden()
                        .overlay(alignment: .trailing) { marker(index) }
                    Blocks(blocks: items[index], depth: depth + 1, spacing: 10)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func marker(_ index: Int) -> some View {
        Text(ordered ? "\(start + index)." : ["•", "◦", "▪"][depth % 3])
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// A table at the width its cells need, long ones wrapped; a table wider than the reply scrolls.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    ForEach(header.indices, id: \.self) { cell(header[$0]).fontWeight(.semibold) }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { cell(rows[row][$0]) }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func cell(_ text: String) -> some View {
        CellLayout { Text(Markdown.inline(text)) }
    }
}

/// A table cell at the width its text needs, wrapped at 320 points. The scroll view proposes no
/// width, and `frame(maxWidth:)` would measure the text unwrapped there and clip its other lines.
private struct CellLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let width = min(text.sizeThatFits(.unspecified).width, proposal.width ?? 320, 320)
        return text.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
