import Foundation

extension ToolCallingMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .required: return "required"
        case .allowed: return "allowed"
        case .none: return "none"
        }
    }
}

extension ContractViolation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .calledToolWhileModeWasNone(let tool):
            return "called \(tool) while tool calling was disabled"
        case .calledUnregisteredTool(let tool):
            return "called unregistered tool \(tool)"
        case .emittedWhileModeWasRequired:
            return "emitted a record before grounding"
        case .requestedZeroTools:
            return "requested an empty tool list"
        }
    }
}

extension ValidationFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .malformedCurrencyCode(let code):
            return "currency code \"\(code)\" is not ISO 4217 alpha-3"
        case .barcodeCheckDigitMismatch(let barcode, let expected, let found):
            return "barcode \(barcode) check digit is \(found), should be \(expected)"
        case .barcodeUnsupportedLength(let barcode, let length):
            return "barcode \(barcode) is \(length) digits, not a GTIN length"
        case .barcodeNonNumeric(let barcode):
            return "barcode \(barcode) contains a non-digit"
        case .nonPositiveQuantity(let label, let quantity):
            return "\"\(label)\" has quantity \(quantity)"
        case .negativeUnitPrice(let label, let minorUnits):
            return "\"\(label)\" has a negative price (\(minorUnits))"
        case .totalMismatch(let declared, let computed, let tolerance):
            return "printed total \(Money.string(minorUnits: declared)) vs summed "
                + "\(Money.string(minorUnits: computed)), tolerance \(Money.string(minorUnits: tolerance))"
        case .tooManyLineItems(let count, let limit):
            return "\(count) line items exceeds the cap of \(limit)"
        case .emptyRecord:
            return "nothing was read from this image"
        }
    }
}

extension TerminationCause: CustomStringConvertible {
    public var description: String {
        switch self {
        case .modelEmittedValidRecord:
            return "model emitted a record that passed every invariant"
        case .validationExhausted(let failures):
            return "validation kept failing (\(failures.count) outstanding)"
        case .toolBudgetExhausted:
            return "tool-call budget exhausted"
        case .turnBudgetExhausted:
            return "turn ceiling reached"
        case .contextBudgetExhausted:
            return "context budget exceeded"
        case .contractViolation(let violation):
            return "contract violation: \(violation)"
        case .modelUnavailable(let reason):
            return "model unavailable: \(reason)"
        }
    }
}

extension ToolPayload: CustomStringConvertible {
    public var description: String {
        switch self {
        case .recognizedText(let lines):
            return "\(lines.count) text line(s)"
        case .barcode(let value):
            return "barcode \(value)"
        case .keyValues(let pairs):
            return "\(pairs.count) field(s)"
        case .unavailable(let reason):
            return "unavailable — \(reason)"
        }
    }
}

extension TraceEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .runStarted(let budget):
            return "run started · \(budget.toolCallsLimit) tool calls, \(budget.turnsLimit) turns"
        case .turnStarted(let index, let mode):
            return "turn \(index) · toolCalling = \(mode)"
        case .toolRequested(let invocation, let granted):
            return granted
                ? "→ \(invocation.tool)"
                : "→ \(invocation.tool) DECLINED (no budget)"
        case .toolRequestsTruncated(let requested, let considered):
            return "requested \(requested) tools in one turn; only the first \(considered) were read"
        case .toolCompleted(let result):
            return result.wasCoalesced
                ? "← \(result.invocation.tool): \(result.payload) (coalesced, free)"
                : "← \(result.invocation.tool): \(result.payload)"
        case .draftEmitted(let record):
            return "draft: \(record.lineItems.count) item(s), barcode \(record.barcode ?? "—")"
        case .validationFailed(let failures):
            return "rejected: " + failures.map(\.description).joined(separator: "; ")
        case .validationPassed:
            return "accepted"
        case .contractViolated(let violation):
            return "contract violated: \(violation)"
        case .modelFailed(let reason):
            return "model failed: \(reason)"
        case .fallbackEngaged(let reason):
            return "fallback engaged — \(reason)"
        case .runFinished(let cause, let budget):
            return "run finished · \(cause) · \(budget.toolCallsUsed)/\(budget.toolCallsLimit) tool calls, "
                + "\(budget.turnsUsed)/\(budget.turnsLimit) turns"
        case .eventsDropped(let count):
            return "\(count) earlier event(s) dropped — trace buffer is bounded"
        }
    }
}
