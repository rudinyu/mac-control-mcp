// Cleans Accessibility text from terminals such as iTerm2, which report one entry per cell:
// NUL pads the second cell of a wide character and also stands for a blank cell.
// Padding after a wide character is dropped, other NULs become spaces, and blanks at the end
// of each line are trimmed so they do not use up the character limit. Text without NUL is
// returned unchanged apart from the limit.
func cleanCellText(_ string: String, limit: Int) -> String {
    guard string.unicodeScalars.contains("\u{0}") else { return String(string.prefix(limit)) }
    var output = String.UnicodeScalarView()
    var pendingBlanks = 0
    var previousIsWide = false
    // Characters never outnumber scalars, so stopping at twice the limit leaves room for combining marks.
    for scalar in string.unicodeScalars {
        if output.count >= limit * 2 { break }
        switch scalar {
        case "\u{0}":
            if !previousIsWide { pendingBlanks += 1 }
            previousIsWide = false
        case " ":
            pendingBlanks += 1
            previousIsWide = false
        case "\n":
            pendingBlanks = 0
            output.append(scalar)
            previousIsWide = false
        default:
            output.append(contentsOf: repeatElement(" ", count: pendingBlanks))
            pendingBlanks = 0
            output.append(scalar)
            previousIsWide = isWide(scalar)
        }
    }
    return String(String(output).prefix(limit))
}

// Approximates Unicode East Asian Width W and F (Unicode 15), which terminals draw in two cells.
func isWide(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x115F,                                   // Hangul Jamo initial consonants
         0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0, 0x23F3,
         0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F, 0x2693, 0x26A1,
         0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE, 0x26D4, 0x26EA,
         0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A...0x270B, 0x2728,
         0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF,
         0x2B1B...0x2B1C, 0x2B50, 0x2B55,                   // emoji-presentation symbols
         0x2E80...0x303E, 0x3041...0x33FF,                  // CJK radicals, punctuation, kana, compatibility
         0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, // CJK ideographs, Yi
         0xA960...0xA97F, 0xAC00...0xD7A3,                  // Hangul
         0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, // compatibility ideographs, vertical and small forms
         0xFF00...0xFF60, 0xFFE0...0xFFE6,                  // fullwidth forms
         0x16FE0...0x16FE4, 0x17000...0x18CFF, 0x1B000...0x1B2FF,
         0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
         0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB,
         0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF,              // emoji
         0x20000...0x2FFFD, 0x30000...0x3FFFD:              // CJK extension planes
        return true
    default:
        return false
    }
}
