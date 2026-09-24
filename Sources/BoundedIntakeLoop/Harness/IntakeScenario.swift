import Foundation

/// The five runs worth looking at.
///
/// These are shared by the unit tests, the eval harness and the demo app's UI.
/// One definition, three consumers: a scenario the demo shows is literally the
/// scenario CI asserts on, so a screenshot cannot drift away from a passing test.
public enum IntakeScenario: String, Sendable, CaseIterable, Identifiable {
    /// The model grounds itself, then emits a record that validates.
    case groundedThenEmit
    /// No model on this device. The deterministic path reads the receipt anyway.
    case modelUnavailable
    /// The model never stops asking for tools. The turn ceiling stops it.
    case runawayModel
    /// The model emits a barcode whose check digit is wrong, repeatedly.
    case hallucinatedBarcode
    /// The model asks for a tool that was never registered.
    case contractViolation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .groundedThenEmit: return "Grounded read"
        case .modelUnavailable: return "No model on device"
        case .runawayModel: return "Runaway tool loop"
        case .hallucinatedBarcode: return "Hallucinated barcode"
        case .contractViolation: return "Contract violation"
        }
    }

    public var summary: String {
        switch self {
        case .groundedThenEmit:
            return "Model calls OCR and the barcode reader, then emits a record that passes every invariant."
        case .modelUnavailable:
            return "The model throws. The loop grounds the photo itself and rebuilds the record from OCR alone."
        case .runawayModel:
            return "The model asks for the same tool forever. Repeats are coalesced for free, so the tool budget never moves — the turn ceiling is what ends the run."
        case .hallucinatedBarcode:
            return "The model keeps emitting a barcode with a bad check digit. Validation rejects it every turn, then the fallback rebuilds the record from the barcode the reader actually saw — same record as scenario 1, different provenance."
        case .contractViolation:
            return "The model requests an unregistered tool. That is not retried — the run ends and the deterministic path takes over."
        }
    }
}

/// Fixtures and pre-wired loops.
public enum IntakeScenarioCatalog {

    // MARK: - Fixtures

    /// A valid EAN-13 (check digit 1).
    public static let validBarcode = "4006381333931"
    /// The same barcode with the check digit transposed — exactly the error a
    /// model makes reading digits off a curved surface.
    public static let hallucinatedBarcodeValue = "4006381333932"

    public static let receiptLines = [
        "ACME MARKET",
        "Milk 2L 3.49",
        "Bread x2 4.50",
        "Coffee 8.99",
        "TAX 1.12",
        "SUBTOTAL 16.98",
        "TOTAL 18.10"
    ]

    /// The record a correct read produces. Line items sum to exactly 1810 minor
    /// units, which is the printed total, so this validates under
    /// ``ValidationPolicy/strict`` with a zero tolerance.
    /// The currency is a parameter, not a constant, because it is the app's
    /// decision and not the library's — the demo app passes its own compiled-in
    /// value straight through to here.
    public static func expectedRecord(currencyCode: String = "USD") -> IntakeRecord {
        IntakeRecord(
            barcode: validBarcode,
            merchant: "ACME MARKET",
            lineItems: [
                LineItem(label: "Milk 2L", quantity: 1, unitPriceMinorUnits: 349),
                LineItem(label: "Bread", quantity: 2, unitPriceMinorUnits: 225),
                LineItem(label: "Coffee", quantity: 1, unitPriceMinorUnits: 899),
                LineItem(label: "TAX", quantity: 1, unitPriceMinorUnits: 112)
            ],
            declaredTotalMinorUnits: 1810,
            currencyCode: currencyCode
        )
    }

    public static let attachment = IntakeAttachment(
        identifier: "acme-receipt",
        hint: "grocery receipt, single column"
    )

    public static func standardTools() -> [any GroundingTool] {
        [
            StaticGroundingTool(
                name: StandardTool.recognizeText,
                payload: .recognizedText(receiptLines)
            ),
            StaticGroundingTool(
                name: StandardTool.readBarcode,
                payload: .barcode(validBarcode)
            )
        ]
    }

    private static let groundingTurn = ModelTurn.callTools([
        ToolInvocation(tool: StandardTool.recognizeText),
        ToolInvocation(tool: StandardTool.readBarcode)
    ])

    // MARK: - Wiring

    public static func model(
        for scenario: IntakeScenario,
        currencyCode: String = "USD"
    ) -> (any IntakeModel)? {
        let good = expectedRecord(currencyCode: currencyCode)
        switch scenario {
        case .groundedThenEmit:
            return ScriptedIntakeModel(
                script: [groundingTurn, .emit(good)],
                whenExhausted: .emit(good)
            )
        case .modelUnavailable:
            return UnavailableIntakeModel()
        case .runawayModel:
            return ScriptedIntakeModel(
                script: [.callTools([ToolInvocation(tool: StandardTool.recognizeText)])],
                whenExhausted: .repeatLast
            )
        case .hallucinatedBarcode:
            let bad = IntakeRecord(
                barcode: hallucinatedBarcodeValue,
                merchant: good.merchant,
                lineItems: good.lineItems,
                declaredTotalMinorUnits: good.declaredTotalMinorUnits,
                currencyCode: good.currencyCode
            )
            return ScriptedIntakeModel(
                script: [groundingTurn, .emit(bad)],
                whenExhausted: .repeatLast
            )
        case .contractViolation:
            return ScriptedIntakeModel(
                script: [.callTools([ToolInvocation(tool: "summarizeReceipt")])],
                whenExhausted: .repeatLast
            )
        }
    }

    /// The runaway scenario deliberately uses a ladder whose terminal rung sits
    /// *beyond* the turn ceiling (1 + 8 = 9 > 6 turns). That isolates one bound
    /// at a time: with the ladder unable to fire, the only thing that can stop
    /// the run is ``BudgetLedger``'s turn count, so the scenario is a real test
    /// of that bound rather than an incidental one.
    public static func ladder(for scenario: IntakeScenario) -> ModeLadder {
        scenario == .runawayModel ? ModeLadder(requiredTurns: 1, allowedTurns: 8) : .default
    }

    public static func loop(
        for scenario: IntakeScenario,
        currencyCode: String = "USD"
    ) -> IntakeLoop {
        IntakeLoop(
            model: model(for: scenario, currencyCode: currencyCode),
            registry: ToolRegistry(tools: standardTools()),
            validator: RecordValidator(policy: .strict),
            fallback: DeterministicIntake(currencyCode: currencyCode),
            ladder: ladder(for: scenario),
            budget: .singlePhoto,
            traceCapacity: 64
        )
    }

    /// Why each scenario stops. Pinned here so a change in the loop's
    /// termination behaviour breaks a test rather than quietly changing what
    /// the demo claims.
    public static func expectedTermination(for scenario: IntakeScenario) -> TerminationCause {
        switch scenario {
        case .groundedThenEmit:
            return .modelEmittedValidRecord
        case .modelUnavailable:
            return .modelUnavailable("model not available on this device")
        case .runawayModel:
            return .turnBudgetExhausted
        case .hallucinatedBarcode:
            return .validationExhausted([
                .barcodeCheckDigitMismatch(barcode: hallucinatedBarcodeValue, expected: 1, found: 2)
            ])
        case .contractViolation:
            return .contractViolation(.calledUnregisteredTool(tool: "summarizeReceipt"))
        }
    }

    /// The expected provenance for each scenario — asserted in tests and shown
    /// in the demo, so the two can never disagree.
    public static func expectedProvenance(for scenario: IntakeScenario) -> Provenance {
        scenario == .groundedThenEmit ? .model : .deterministicFallback
    }

    /// What each scenario is *expected* to spend, which is deliberately tighter
    /// than the ledger's ceiling.
    ///
    /// Pinning the eval's ceiling to `IntakeBudget.singlePhoto.toolCalls` would
    /// make the check unfalsifiable: the ledger grants `min(request, remaining)`
    /// against that same number, so "used <= limit" is true by construction. A
    /// tighter, hand-written number is a real expectation — the runaway case in
    /// particular passes only because repeats are coalesced, so if coalescing
    /// broke, its `1` would become `4` and this eval would go red.
    public static func expectedToolCalls(for scenario: IntakeScenario) -> Int {
        scenario == .runawayModel ? 1 : 2
    }

    /// The eval suite. Every case pins provenance and a tool-call ceiling; the
    /// grounded case additionally pins the exact record.
    public static func evalCases(currencyCode: String = "USD") -> [IntakeEvalCase] {
        IntakeScenario.allCases.map { scenario in
            IntakeEvalCase(
                name: scenario.title,
                loop: loop(for: scenario, currencyCode: currencyCode),
                attachment: attachment,
                expectedProvenance: expectedProvenance(for: scenario),
                expectedRecord: scenario == .groundedThenEmit
                    ? .some(expectedRecord(currencyCode: currencyCode))
                    : nil,
                maximumToolCalls: expectedToolCalls(for: scenario),
                // The hallucinated-barcode run ends with a fallback record that
                // is clean precisely because the fallback refuses the bad
                // barcode. The contract-violation run is clean for the same
                // reason. Nothing here is allowed to carry failures forward.
                requiresCleanValidation: true
            )
        }
    }
}
