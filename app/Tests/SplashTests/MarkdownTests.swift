import Foundation
import SwiftUI
import Testing

@testable import Splash

struct MarkdownTests {
    @Test func readsParagraphsHeadingsAndRules() {
        #expect(Markdown.blocks("""
            # Title
            One line
              and the next

            ## Closed ##
            ####### Seven
            #NoSpace
            ---
            * * *
            """) == [
            .heading(level: 1, "Title"),
            .paragraph("One line\nand the next"),
            .heading(level: 2, "Closed"),
            .paragraph("####### Seven\n#NoSpace"),
            .rule,
            .rule,
        ])
        #expect(Markdown.blocks("### C#").first == .heading(level: 3, "C#"))
        #expect(Markdown.blocks("").isEmpty)
        #expect(Markdown.blocks("\n\n  \n").isEmpty)
    }

    @Test func readsFencedCode() {
        #expect(Markdown.blocks("""
            Run:
            ```swift title="a"
            let a = 1

              print(a)
            ```
            ~~~
            ```
            ~~~
            ````md
            ```
            ````
            """) == [
            .paragraph("Run:"),
            .code(language: "swift", "let a = 1\n\n  print(a)"),
            .code(language: nil, "```"),
            .code(language: "md", "```"),
        ])
        // An indented fence takes its indentation off its lines.
        #expect(Markdown.blocks("  ```\n  a\n    b\n  ```") == [.code(language: nil, "a\n  b")])
        // Backticks in the info string make it text, as inline code.
        #expect(Markdown.blocks("``` a`b") == [.paragraph("``` a`b")])
    }

    @Test func runsAnOpenFenceToTheEnd() {
        #expect(Markdown.blocks("Text\n```py\nprint(1)\n") == [.paragraph("Text"), .code(language: "py", "print(1)")])
        #expect(Markdown.blocks("```py\nprint(1)\n\n# not a heading") == [.code(language: "py", "print(1)\n\n# not a heading")])
        #expect(Markdown.blocks("```") == [.code(language: nil, "")])
    }

    @Test func readsLists() {
        #expect(Markdown.blocks("""
            - one
            - two
              - nested
                more
            * three
            """) == [
            .list(ordered: false, start: 1, items: [
                [.paragraph("one")],
                [.paragraph("two"), .list(ordered: false, start: 1, items: [[.paragraph("nested\nmore")]])],
                [.paragraph("three")],
            ]),
        ])
        #expect(Markdown.blocks("3. three\n4) four\n\n   still four\n\n5. five\nAfter") == [
            .list(ordered: true, start: 3, items: [
                [.paragraph("three")],
                [.paragraph("four"), .paragraph("still four")],
                [.paragraph("five")],
            ]),
            .paragraph("After"),
        ])
        // A nested list needs only to be indented past its parent's marker.
        #expect(Markdown.blocks("1. Step\n  - detail\n2. Next") == [
            .list(ordered: true, start: 1, items: [
                [.paragraph("Step"), .list(ordered: false, start: 1, items: [[.paragraph("detail")]])],
                [.paragraph("Next")],
            ]),
        ])
        // A different kind of list starts a new list; a blank line and text end one.
        #expect(Markdown.blocks("- a\n1. b\n\nText") == [
            .list(ordered: false, start: 1, items: [[.paragraph("a")]]),
            .list(ordered: true, start: 1, items: [[.paragraph("b")]]),
            .paragraph("Text"),
        ])
        #expect(Markdown.blocks("-\n- \n-x") == [.list(ordered: false, start: 1, items: [[], []]), .paragraph("-x")])
    }

    @Test func startsListsInTextOnlyAtBulletsAndOne() {
        #expect(Markdown.blocks("Steps:\n1. a\n- b") == [
            .paragraph("Steps:"),
            .list(ordered: true, start: 1, items: [[.paragraph("a")]]),
            .list(ordered: false, start: 1, items: [[.paragraph("b")]]),
        ])
        #expect(Markdown.blocks("Born in\n1984. Moved later.") == [.paragraph("Born in\n1984. Moved later.")])
        #expect(Markdown.blocks("1984. A list after all") == [
            .list(ordered: true, start: 1984, items: [[.paragraph("A list after all")]]),
        ])
    }

    @Test func keepsCodeInAListItem() {
        #expect(Markdown.blocks("""
            1. Install:

               ```sh
               make

               make install
               ```
            2. Run:
               ```
            # under-indented
               ```
            3. Done
            """) == [
            .list(ordered: true, start: 1, items: [
                [.paragraph("Install:"), .code(language: "sh", "make\n\nmake install")],
                [.paragraph("Run:"), .code(language: nil, "# under-indented")],
                [.paragraph("Done")],
            ]),
        ])
        #expect(Markdown.blocks("- ```\n  open") == [
            .list(ordered: false, start: 1, items: [[.code(language: nil, "open")]]),
        ])
    }

    @Test func readsQuotes() {
        #expect(Markdown.blocks("""
            > Quoted
            >continues
            >
            > > nested
            > - item
            after
            """) == [
            .quote([
                .paragraph("Quoted\ncontinues"),
                .quote([.paragraph("nested")]),
                .list(ordered: false, start: 1, items: [[.paragraph("item")]]),
            ]),
            .paragraph("after"),
        ])
    }

    @Test func readsTables() {
        #expect(Markdown.blocks("""
            Compare:
            | Name | Value |
            |:-----|------:|
            | `a \\| b` | 1 |
            | two<br>lines |
            c | 3 | extra
            after
            """) == [
            .paragraph("Compare:"),
            .table(header: ["Name", "Value"], rows: [["`a | b`", "1"], ["two\nlines", ""], ["c", "3"]]),
            .paragraph("after"),
        ])
        #expect(Markdown.blocks("  a | b  \n--|:-: ") == [.table(header: ["a", "b"], rows: [])])
        // The delimiter row must match the header.
        #expect(Markdown.blocks("a | b\n|---|") == [.paragraph("a | b\n|---|")])
        #expect(Markdown.blocks("a | b\n| - | x |") == [.paragraph("a | b\n| - | x |")])
    }

    @Test func readsWindowsLineEndings() {
        #expect(Markdown.blocks("# T\r\n\r\n- a\r\n- b\r\n\r\n```\r\nx\r\n```\r\n") == [
            .heading(level: 1, "T"),
            .list(ordered: false, start: 1, items: [[.paragraph("a")], [.paragraph("b")]]),
            .code(language: nil, "x"),
        ])
    }

    @Test func limitsNesting() {
        let deep = Markdown.blocks(String(repeating: "> ", count: 5000) + "deep")
        var depth = 0
        var blocks = deep
        while case .quote(let inner) = blocks.first {
            depth += 1
            blocks = inner
        }
        #expect(depth == 10)
        #expect(Markdown.blocks(String(repeating: "- ", count: 5000) + "x").count == 1)
    }

    @Test func parsesALongReplyQuickly() {
        let section = """
            ## Section

            Some **bold** text, `code`, and a [link](https://example.com) | with a pipe.
            A second line of the paragraph that goes on for a while to make it longer.

            - item one
              - nested item
            - item two

            1. first
            2. second

            ```swift
            func f() {
                print("hello")
            }
            ```

            > a quote

            | a | b |
            |---|---|
            | 1 | 2 |


            """
        // Linear: four times the text takes about four times as long, far from sixteen. A ratio,
        // not a time, so a slow or busy machine does not fail it.
        let clock = ContinuousClock()
        func time(_ text: String) -> Double {
            _ = Markdown.blocks(text)
            let elapsed = clock.measure { _ = Markdown.blocks(text) }
            return Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
        }
        let reply = String(repeating: section, count: 50_000 / section.utf8.count + 1)
        #expect(reply.utf8.count > 50_000)
        #expect(time(reply + reply + reply + reply) / time(reply) < 8)
        // Pathological lines stay linear too.
        let blanks = { (count: Int) in "- a\n" + String(repeating: "\n", count: count) + "b" }
        #expect(time(blanks(200_000)) / time(blanks(50_000)) < 8)
    }

    @Test func styledInline() {
        let text = Markdown.inline("**b** `c` [web](https://a.b) [file](file:///Applications) ![cat](https://a.b/cat.png)")
        #expect(String(text.characters) == "b c web file cat")
        #expect(text.runs.compactMap { $0.link } == [URL(string: "https://a.b")!, URL(string: "https://a.b/cat.png")!])
        #expect(text.runs.allSatisfy { $0.imageURL == nil })
        #expect(text.runs.contains {
            $0.inlinePresentationIntent == .code && $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil
        })
    }

    /// A sample reply drawn to `markdown-light.png` and `markdown-dark.png` when `SPLASH_APP_SNAPSHOTS`
    /// names a folder, for people to review the look.
    @MainActor @Test func markdownShowcase() async {
        let size = CGSize(width: 720, height: 900)
        await Snapshot.save("markdown", size: size,
                            MarkdownView(text: Self.showcase).padding(32).frame(width: size.width, height: size.height, alignment: .top))
    }

    static let showcase = """
        # Getting started with Splash

        Splash runs models **privately** on this Mac. Replies can use *emphasis*, `inline code`, \
        ~~strikethrough~~, and [links](https://example.com); an image shows as a link: ![diagram](https://example.com/d.png).

        ## Install

        1. Download the app and open it.
        2. Pick a model:
           - **Small** models start fast
           - **Large** models answer better
             - but need more memory
        3. Start chatting.

        ```bash
        curl -fsSL https://example.com/install.sh | sh
        splash serve --model mlx-community/Qwen3-30B-A3B-4bit --port 8000 --max-context 32K --kv-format bf16
        ```

        ### Comparison

        | Model | Memory | Speed | Notes |
        |:------|-------:|------:|-------|
        | Small | 16 GB | 95 tok/s | Good for quick questions |
        | Large | 64 GB | 38 tok/s | Better at code and long documents<br>Slower to load |
        | Largest | 128 GB | 21 tok/s | The best answers of the three, for the longest and hardest work, if the Mac has the memory for it |

        > Models never leave this Mac. Nothing you type is sent anywhere.
        >
        > — The Splash team

        ---

        ```
        plain code without a language
        ```

        - Done
        """
}
