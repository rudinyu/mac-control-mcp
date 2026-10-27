// Unit tests for cleanCellText and isWide. Built with Sources/TerminalText.swift by scripts/build.sh.

import Foundation

private var failures = 0

private func check(_ name: String, _ input: String, limit: Int = 200, _ expected: String) {
    let actual = cleanCellText(input, limit: limit)
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\n     expected: \(expected.debugDescription)\n     actual:   \(actual.debugDescription)")
    }
}

private func checkWide(_ scalar: Unicode.Scalar, _ expected: Bool) {
    if isWide(scalar) == expected {
        print("ok   isWide U+\(String(scalar.value, radix: 16, uppercase: true))")
    } else {
        failures += 1
        print("FAIL isWide U+\(String(scalar.value, radix: 16, uppercase: true)) expected \(expected)")
    }
}

@main
private enum TerminalTextTests {
    static func main() {
        check("empty string", "", "")
        check("text without NUL is unchanged", "  keep  spaces  ", "  keep  spaces  ")
        check("text without NUL respects limit", "abcdef", limit: 3, "abc")
        check("all NUL", "\u{0}\u{0}\u{0}", "")
        check("leading NUL becomes spaces", "\u{0}\u{0}ab", "  ab")
        check("NUL between narrow words is a space", "other\u{0}app", "other app")
        check("padding after wide character is dropped", "中\u{0}文\u{0}", "中文")
        check("wide padding then blank cell", "中\u{0}\u{0}x", "中 x")
        check("emoji padding is dropped", "🚀\u{0}go", "🚀go")
        check("trailing blanks on each line are trimmed", "ab\u{0}\u{0}  \ncd\u{0}\u{0}", "ab\ncd")
        check("blank runs do not use up the limit", "a" + String(repeating: "\u{0}", count: 500) + "\nb", limit: 5, "a\nb")
        check("original iTerm2 sample",
              " \u{0}\u{0}\u{0}session：\u{0}「\u{0}mac_status\u{0}呼\u{0}叫\u{0}」\u{0}\n\u{0}\u{0}-\u{0}Tue Oct\u{0}27 11:41。\u{0}",
              "    session：「mac_status 呼叫」\n  - Tue Oct 27 11:41。")
        check("CRLF trims trailing blanks", "ab\u{0} \r\ncd\u{0}", "ab\r\ncd")
        check("zero limit", "ab\u{0}", limit: 0, "")
        check("negative limit", "ab", limit: -1, "")
        check("combining marks count as one character", "e\u{301}\u{0}e\u{301}\u{0}", limit: 2, "e\u{301} ")
        check("large input stops early", String(repeating: "x\u{0}", count: 200_000), limit: 3, "x x")
        check("limit applies after cleaning", "中\u{0}文\u{0}字\u{0}", limit: 2, "中文")

        checkWide("a", false)
        checkWide("中", true)
        checkWide("가", true)
        checkWide("Ａ", true)
        checkWide("🚀", true)
        checkWide("✅", true)
        checkWide("\u{303F}", false)
        checkWide("⏺", false)

        if failures > 0 {
            print("\(failures) terminal text test(s) failed")
            exit(1)
        }
        print("All terminal text tests passed")
    }
}
