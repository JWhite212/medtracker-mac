import Foundation

// Ports the pure CSV-escaping and dose-row-building halves of
// `src/lib/server/export-csv.ts` — `escapeCsvCell` and the row/header
// construction inside `generateCsvReport`. The DB query that fetches dose
// rows (and the eventual file emission via `NSSavePanel`) is NOT part of
// this task: this module only turns already-formatted values the caller
// supplies into CSV text.

// MARK: - Cell escaping

/// Characters that trigger the formula-injection guard when they are the
/// cell's *first* character — mirrors the TS regex `^[=+\-@\t\r]`
/// (`export-csv.ts:16`). Modeled as `Unicode.Scalar`, not `Character`:
/// Swift's `Character` is an extended grapheme cluster, and a CR
/// immediately followed by LF collapses into a *single* `Character`
/// (`"\r\n"` as one grapheme) that matches neither `"\r"` nor `"\n"` alone —
/// scanning `unicodeScalars` instead sidesteps that entirely.
private let formulaInjectionPrefixes: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\t", "\r"]

/// Characters that force the cell to be quote-wrapped when present
/// *anywhere* — mirrors the TS regex `[",\r\n]` (`export-csv.ts:18`). See
/// the note on `formulaInjectionPrefixes` above for why this is a
/// `Unicode.Scalar` set rather than a `Character` set.
private let quotingTriggers: Set<Unicode.Scalar> = ["\"", ",", "\r", "\n"]

/// Escape a single CSV cell. Ports `escapeCsvCell` (`export-csv.ts:14-22`).
///
/// - `nil` renders as an empty cell (mirrors the TS `null`/`undefined`
///   check). The TS version accepts `unknown` and stringifies numbers and
///   booleans via `String(value)`; since this port's callers already hold
///   formatted `String`s, that stringification is the caller's
///   responsibility, not this function's.
/// - A cell whose first character is `= + - @` or TAB(`\t`)/CR(`\r`) gets a
///   leading `'` to neutralise spreadsheet formula injection (CWE-1236).
///   This check runs against the *raw* string, before quote-doubling.
/// - Internal `"` are doubled per RFC 4180.
/// - The (quote-doubled) cell is wrapped in `"..."` when it contains a `"`,
///   `,`, CR, or LF — checked against the *escaped* string, matching the TS
///   order of operations exactly (prefix guard, then quote-doubling, then
///   the wrap test).
public func escapeCsvCell(_ value: String?) -> String {
    let raw = value ?? ""
    let safe: String
    if let first = raw.unicodeScalars.first, formulaInjectionPrefixes.contains(first) {
        safe = "'" + raw
    } else {
        safe = raw
    }
    let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
    if escaped.unicodeScalars.contains(where: { quotingTriggers.contains($0) }) {
        return "\"\(escaped)\""
    }
    return escaped
}

// MARK: - Dose CSV row builder

/// A single side-effect entry as rendered into the "Side Effects" column —
/// mirrors the TS `{ name, severity }` shape
/// (`src/lib/server/db/schema.ts:121-124`, `severity` is
/// `"mild" | "moderate" | "severe"`).
public struct CsvSideEffect: Equatable {
    public let name: String
    public let severity: String

    public init(name: String, severity: String) {
        self.name = name
        self.severity = severity
    }
}

/// One dose-log row's already-formatted display values, as consumed by
/// `doseCsvRows`. Deliberately holds only pre-formatted `String`s — no DB
/// query, no timezone-aware date/time formatting, and no `Decimal`
/// arithmetic happens in this module. The caller (a later task, outside
/// domain-core) is responsible for producing the localized date/time
/// strings and stringifying `dosageAmount`/`quantity`/`notes`, mirroring how
/// `generateCsvReport` (`export-csv.ts:58-76`) formats each field before
/// calling `escapeCsvCell`.
public struct DoseCsvRow: Equatable {
    public let date: String
    public let time: String
    public let status: String
    public let medicationName: String
    public let dosageAmount: String
    public let dosageUnit: String
    public let quantity: String
    public let notes: String
    public let sideEffects: [CsvSideEffect]

    public init(
        date: String,
        time: String,
        status: String,
        medicationName: String,
        dosageAmount: String,
        dosageUnit: String,
        quantity: String,
        notes: String,
        sideEffects: [CsvSideEffect] = []
    ) {
        self.date = date
        self.time = time
        self.status = status
        self.medicationName = medicationName
        self.dosageAmount = dosageAmount
        self.dosageUnit = dosageUnit
        self.quantity = quantity
        self.notes = notes
        self.sideEffects = sideEffects
    }
}

/// The dose-CSV column header, in order (`export-csv.ts:47-56`).
private let doseCsvHeader = [
    "Date", "Time", "Status", "Medication", "Dosage", "Quantity", "Notes", "Side Effects",
].joined(separator: ",")

/// Ports the row-building + line-joining half of `generateCsvReport`
/// (`export-csv.ts:58-79`) — everything except the DB query that produces
/// `doses`.
///
/// - `Dosage` concatenates `dosageAmount` + `dosageUnit` with **no space**
///   (`` `${dose.dosageAmount}${dose.dosageUnit}` ``, `export-csv.ts:71`).
/// - `Side Effects` joins each entry as `"name (severity)"` with `"; "`
///   (`export-csv.ts:64`), or renders empty when there are none.
/// - The header and every row are joined with CRLF (`\r\n`) per RFC 4180 —
///   Excel and Numbers both prefer it (`export-csv.ts:78-79`).
public func doseCsvRows(_ doses: [DoseCsvRow]) -> String {
    let rows = doses.map { dose -> String in
        let sideEffects = dose.sideEffects
            .map { "\($0.name) (\($0.severity))" }
            .joined(separator: "; ")

        return [
            escapeCsvCell(dose.date),
            escapeCsvCell(dose.time),
            escapeCsvCell(dose.status),
            escapeCsvCell(dose.medicationName),
            escapeCsvCell("\(dose.dosageAmount)\(dose.dosageUnit)"),
            escapeCsvCell(dose.quantity),
            escapeCsvCell(dose.notes),
            escapeCsvCell(sideEffects),
        ].joined(separator: ",")
    }

    return ([doseCsvHeader] + rows).joined(separator: "\r\n")
}
