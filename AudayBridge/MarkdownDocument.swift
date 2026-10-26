import SwiftUI

/// Lightweight native Markdown presentation; content is data and never executes HTML.
struct MarkdownDocument: View {
    let source: String
    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String] = []; var fenced = false
        for line in source.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if fenced { result.append(Block(text: code.joined(separator: "\n"), style: .code)); code = [] }
                fenced.toggle(); continue
            }
            if fenced { code.append(line); continue }
            if line.hasPrefix("### ") { result.append(Block(text: String(line.dropFirst(4)), style: .heading(3))) }
            else if line.hasPrefix("## ") { result.append(Block(text: String(line.dropFirst(3)), style: .heading(2))) }
            else if line.hasPrefix("# ") { result.append(Block(text: String(line.dropFirst(2)), style: .heading(1))) }
            else if line == "---" || line == "***" { result.append(Block(text: "", style: .rule)) }
            else if line.hasPrefix("> ") { result.append(Block(text: String(line.dropFirst(2)), style: .quote)) }
            else { result.append(Block(text: line, style: .body)) }
        }
        if fenced { result.append(Block(text: code.joined(separator: "\n"), style: .code)) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.style {
                case .heading(let level): Text(.init(block.text)).font(level == 1 ? .title : level == 2 ? .title2 : .title3).bold().padding(.top, 8)
                case .code: Text(block.text).font(.system(.body, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary).cornerRadius(6)
                case .quote: Text(.init(block.text)).foregroundStyle(.secondary).padding(.leading, 12)
                case .rule: Divider().padding(.vertical, 8)
                case .body: Text(.init(block.text.isEmpty ? " " : block.text)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private struct Block { let text: String; let style: Style }
    private enum Style { case heading(Int), body, code, quote, rule }
}
