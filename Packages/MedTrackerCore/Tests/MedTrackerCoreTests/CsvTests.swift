import Foundation
@testable import MedTrackerCore
import Testing

// Transcribes `describe("escapeCsvCell", ...)` from
// `tests/unit/export-csv.test.ts:9-58` verbatim (exact escaped outputs). The
// TS `escapeCsvCell` takes `unknown` and stringifies numbers/booleans via
// `String(value)`; this Swift port takes `String?`, so the "plain values"
// case is expressed as already-stringified input rather than passing a
// number/bool directly.

@Test func escapeCsvCell_passesThroughPlainValues() {
    #expect(escapeCsvCell("hello") == "hello")
    #expect(escapeCsvCell("42") == "42")
    #expect(escapeCsvCell("true") == "true")
}

@Test func escapeCsvCell_rendersNilAsAnEmptyCell() {
    // TS also asserts `undefined` renders empty; `String?` collapses
    // null/undefined into a single `nil` case.
    #expect(escapeCsvCell(nil) == "")
}

@Test func escapeCsvCell_doublesEmbeddedDoubleQuotesAndWrapsTheCell() {
    #expect(escapeCsvCell("say \"hi\"") == "\"say \"\"hi\"\"\"")
}

@Test func escapeCsvCell_wrapsCellsContainingCommas() {
    #expect(escapeCsvCell("one, two") == "\"one, two\"")
}

@Test func escapeCsvCell_wrapsCellsContainingNewlinesAndCRLF() {
    #expect(escapeCsvCell("line1\nline2") == "\"line1\nline2\"")
    #expect(escapeCsvCell("line1\r\nline2") == "\"line1\r\nline2\"")
}

@Test func escapeCsvCell_neutralisesFormulaInjectionPrefixes() {
    #expect(escapeCsvCell("=SUM(A1)") == "'=SUM(A1)")
    #expect(escapeCsvCell("+1234") == "'+1234")
    #expect(escapeCsvCell("-1234") == "'-1234")
    #expect(escapeCsvCell("@cmd") == "'@cmd")
}

@Test func escapeCsvCell_neutralisesWhitespacePrefixedFormulasTab() {
    // Tab is in the prefix regex but not the wrap regex.
    #expect(escapeCsvCell("\t=evil") == "'\t=evil")
}

@Test func escapeCsvCell_crPrefixedInputIsBothPrefixNeutralisedAndQuoteWrapped() {
    // Cells containing CR or LF must be wrapped per RFC 4180.
    #expect(escapeCsvCell("\rnope") == "\"'\rnope\"")
}

@Test func escapeCsvCell_combinesPrefixNeutralisationWithQuoteWrapping() {
    // Cell that needs both: starts with `=` AND contains a comma.
    let result = escapeCsvCell("=cmd,arg")
    #expect(result.hasPrefix("\"'"))
    #expect(result.hasSuffix("\""))
    #expect(result.contains("=cmd,arg"))
}

// MARK: - doseCsvRows

// Not transcribed from a TS test file (the DB-querying half of
// `generateCsvReport` is out of scope for this task) — these exercise the
// pure row/header-building port of `export-csv.ts:47-79` directly.

private func makeRow(
    date: String = "2026-07-25",
    time: String = "9:00 AM",
    status: String = "taken",
    medicationName: String = "Lisinopril",
    dosageAmount: String = "10",
    dosageUnit: String = "mg",
    quantity: String = "1",
    notes: String = "",
    sideEffects: [CsvSideEffect] = []
) -> DoseCsvRow {
    DoseCsvRow(
        date: date,
        time: time,
        status: status,
        medicationName: medicationName,
        dosageAmount: dosageAmount,
        dosageUnit: dosageUnit,
        quantity: quantity,
        notes: notes,
        sideEffects: sideEffects
    )
}

@Test func doseCsvRows_producesTheHeaderRowVerbatimWhenEmpty() {
    #expect(doseCsvRows([]) == "Date,Time,Status,Medication,Dosage,Quantity,Notes,Side Effects")
}

@Test func doseCsvRows_concatenatesDosageAmountAndUnitWithNoSpace() {
    let csv = doseCsvRows([makeRow()])
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines.count == 2)
    #expect(lines[0] == "Date,Time,Status,Medication,Dosage,Quantity,Notes,Side Effects")
    #expect(lines[1] == "2026-07-25,9:00 AM,taken,Lisinopril,10mg,1,,")
}

@Test func doseCsvRows_joinsMultipleSideEffectsWithSemicolonSpace() {
    let row = makeRow(
        medicationName: "Ibuprofen",
        dosageAmount: "200",
        sideEffects: [
            CsvSideEffect(name: "Nausea", severity: "mild"),
            CsvSideEffect(name: "Headache", severity: "moderate"),
        ]
    )
    let csv = doseCsvRows([row])
    let lines = csv.components(separatedBy: "\r\n")
    // No comma/quote/CR/LF in the joined string, so it is NOT quote-wrapped.
    #expect(lines[1] == "2026-07-25,9:00 AM,taken,Ibuprofen,200mg,1,,Nausea (mild); Headache (moderate)")
}

@Test func doseCsvRows_rendersEmptySideEffectsAsAnEmptyCell() {
    let csv = doseCsvRows([makeRow(sideEffects: [])])
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines[1].hasSuffix(",,"))
}

@Test func doseCsvRows_escapesFieldsThatContainCommasOrQuotes() {
    let row = makeRow(
        medicationName: "Med, A",
        dosageAmount: "5",
        quantity: "2",
        notes: "felt \"off\", but ok"
    )
    let csv = doseCsvRows([row])
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines[1] == "2026-07-25,9:00 AM,taken,\"Med, A\",5mg,2,\"felt \"\"off\"\", but ok\",")
}

@Test func doseCsvRows_neutralisesFormulaInjectionInAnyColumn() {
    let row = makeRow(notes: "=cmd()")
    let csv = doseCsvRows([row])
    let lines = csv.components(separatedBy: "\r\n")
    #expect(lines[1] == "2026-07-25,9:00 AM,taken,Lisinopril,10mg,1,'=cmd(),")
}

@Test func doseCsvRows_joinsMultipleRowsWithCRLF() {
    let row1 = makeRow(date: "2026-07-25", time: "9:00 AM", medicationName: "A", dosageAmount: "1", dosageUnit: "mg")
    let row2 = makeRow(
        date: "2026-07-24",
        time: "8:00 PM",
        status: "skipped",
        medicationName: "B",
        dosageAmount: "2",
        dosageUnit: "mL"
    )
    let csv = doseCsvRows([row1, row2])
    #expect(
        csv ==
            "Date,Time,Status,Medication,Dosage,Quantity,Notes,Side Effects\r\n" +
            "2026-07-25,9:00 AM,taken,A,1mg,1,,\r\n" +
            "2026-07-24,8:00 PM,skipped,B,2mL,1,,"
    )
}
