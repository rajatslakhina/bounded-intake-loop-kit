#if canImport(SwiftUI)
import SwiftUI

/// Drives the demo. One `@MainActor` class so every mutation of published state
/// happens on the main actor by construction, and the only `await` boundary is
/// the loop run itself.
@MainActor
public final class IntakeDemoModel: ObservableObject {
    @Published public private(set) var scenario: IntakeScenario
    @Published public private(set) var result: IntakeResult?
    @Published public private(set) var evalReport: IntakeEvalReport?
    @Published public private(set) var isRunning = false

    /// Compiled-in defaults owned by the app, not the library — the app decides
    /// which currency and which policy its intake screen runs under.
    public let currencyCode: String

    public init(scenario: IntakeScenario = .groundedThenEmit, currencyCode: String = "USD") {
        self.scenario = scenario
        self.currencyCode = currencyCode
    }

    public func select(_ scenario: IntakeScenario) async {
        self.scenario = scenario
        await run()
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        let loop = IntakeScenarioCatalog.loop(for: scenario, currencyCode: currencyCode)
        let outcome = await loop.run(IntakeScenarioCatalog.attachment)
        result = outcome
        isRunning = false
    }

    public func runEvalSuite() async {
        guard !isRunning else { return }
        isRunning = true
        evalReport = await IntakeEvalHarness().run(
            IntakeScenarioCatalog.evalCases(currencyCode: currencyCode)
        )
        isRunning = false
    }
}

/// The demo screen.
///
/// Everything visible is produced by a real run of ``IntakeLoop`` against the
/// scripted provider — the budget meters, the provenance badge and the trace are
/// read off the ``IntakeResult``, not hardcoded. Switching scenarios re-runs the
/// loop, so the screen is the loop's behaviour rather than a picture of it.
public struct IntakeDemoView: View {
    @StateObject private var model: IntakeDemoModel

    public init(currencyCode: String = "USD") {
        _model = StateObject(wrappedValue: IntakeDemoModel(currencyCode: currencyCode))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scenarioPicker
                    Text(model.scenario.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let result = model.result {
                        provenanceBadge(result)
                        budgetMeters(result)
                        recordCard(result)
                        traceList(result)
                    } else {
                        ProgressView("Running the loop…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }

                    evalSection
                }
                .padding(20)
            }
            .navigationTitle("Bounded Intake Loop")
        }
        .task {
            // Runs on first appearance so the default state is never an empty
            // screen waiting for a tap.
            if model.result == nil { await model.run() }
        }
    }

    // MARK: - Sections

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCENARIO")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(IntakeScenario.allCases) { scenario in
                        Button {
                            Task { await model.select(scenario) }
                        } label: {
                            Text(scenario.title)
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(
                                        scenario == model.scenario
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.secondary.opacity(0.10)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isRunning)
                    }
                }
            }
        }
    }

    private func provenanceBadge(_ result: IntakeResult) -> some View {
        let label: String
        let tint: Color
        switch result.provenance {
        case .model:
            label = "READ BY MODEL"
            tint = .green
        case .deterministicFallback:
            label = "DETERMINISTIC FALLBACK"
            tint = .orange
        case .none:
            label = "NOTHING READ"
            tint = .red
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
            Text(result.termination.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgetMeters(_ result: IntakeResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            meter(
                title: "Tool calls",
                used: result.budget.toolCallsUsed,
                limit: result.budget.toolCallsLimit
            )
            meter(
                title: "Turns",
                used: result.budget.turnsUsed,
                limit: result.budget.turnsLimit
            )
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func meter(title: String, used: Int, limit: Int) -> some View {
        // `limit` is clamped to at least 1 by `IntakeBudget`, but the divide is
        // guarded here too: this view must not be the thing that crashes if a
        // caller ever constructs a snapshot by hand.
        let fraction = limit > 0 ? min(1.0, Double(used) / Double(limit)) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.footnote.weight(.medium))
                Spacer()
                Text("\(used) / \(limit)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(fraction >= 1.0 ? .orange : .accentColor)
        }
    }

    @ViewBuilder
    private func recordCard(_ result: IntakeResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECORD")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let record = result.record {
                field("Merchant", record.merchant ?? "—")
                field("Barcode", record.barcode ?? "— (dropped: failed its check digit)")
                Divider()
                ForEach(Array(record.lineItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.quantity > 1 ? "\(item.label) ×\(item.quantity)" : item.label)
                            .font(.callout)
                        Spacer()
                        Text(Money.string(minorUnits: item.extendedMinorUnits))
                            .font(.callout.monospacedDigit())
                    }
                }
                Divider()
                HStack {
                    Text("Total (printed)").font(.callout.weight(.semibold))
                    Spacer()
                    Text(record.declaredTotalMinorUnits.map { Money.string(minorUnits: $0) } ?? "—")
                        .font(.callout.weight(.semibold).monospacedDigit())
                }
                HStack {
                    Text("Total (summed)").font(.footnote)
                    Spacer()
                    Text(Money.string(minorUnits: record.computedTotalMinorUnits))
                        .font(.footnote.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            } else {
                Text("The model produced nothing usable and there was no evidence to fall back on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !result.outstandingFailures.isEmpty {
                Divider()
                ForEach(Array(result.outstandingFailures.enumerated()), id: \.offset) { _, failure in
                    Label(failure.description, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout).multilineTextAlignment(.trailing)
        }
    }

    private func traceList(_ result: IntakeResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRACE (\(result.trace.count) EVENTS)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(result.trace.enumerated()), id: \.offset) { _, event in
                Text(event.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var evalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.runEvalSuite() }
            } label: {
                Label("Run the pinned eval suite", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)

            if let report = model.evalReport {
                Text("\(report.passedCount) / \(report.totalCount) cases passed")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(report.passed ? .green : .red)
                ForEach(Array(report.outcomes.enumerated()), id: \.offset) { _, outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            outcome.name,
                            systemImage: outcome.passed ? "checkmark.circle" : "xmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(outcome.passed ? .green : .red)
                        Text("\(outcome.toolCallsUsed) tool call(s), \(outcome.turnsUsed) turn(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }
}
#endif
