// Splitting text into lines and delimited fields.
//
// Works on Unicode scalars, never on Characters: in Swift "\r\n" is a single
// Character, so a Character loop that looks for "\n" never sees a Windows line
// break (text-unicode-and-filenames.md §6, porting notes).

enum DelimitedText {
    /// Splits on CR, LF and CRLF (G4-15: old-Mac CR-only files, which Music's
    /// export has used, became one line in the Electron app).
    static func lines(_ text: Substring) -> [Substring] {
        var result: [Substring] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" || scalar == "\r" {
                result.append(Substring(scalars[start..<index]))
                var next = scalars.index(after: index)
                if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" {
                    next = scalars.index(after: next)
                }
                index = next
                start = next
            } else {
                index = scalars.index(after: index)
            }
        }
        if start < scalars.endIndex {
            result.append(Substring(scalars[start..<scalars.endIndex]))
        }
        return result
    }

    /// RFC 4180 rows: quoted fields may hold the delimiter and line breaks,
    /// and `""` inside quotes is one `"`. Kept from the Electron parser
    /// (`app.js:1878-1897`): a quote opens a quoted field only at the start of
    /// a field, and text after a closing quote joins the same field. New: a
    /// quote after leading spaces also opens one (`a, "b,c"`), any of comma,
    /// semicolon or tab can be the delimiter, and CR, LF and CRLF all end a
    /// row. A trailing line break doesn't add an empty row; a blank line in
    /// the middle gives a row with one empty field.
    static func rows(_ text: Substring, delimiter: Unicode.Scalar) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
                continue
            }
            if c == "\"", field.allSatisfy({ $0 == " " }) {
                field = String.UnicodeScalarView()
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\r" || c == "\n" {
                endField()
                rows.append(row)
                row = []
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }

    /// The fields of a single line.
    static func fields(_ line: Substring, delimiter: Unicode.Scalar) -> [String] {
        rows(line, delimiter: delimiter).first ?? []
    }
}
