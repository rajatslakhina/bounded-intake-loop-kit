# BoundedIntakeLoop

**An agent loop that stops for reasons the model does not control.**

iOS 26 put a model on the device; iOS 27 added image attachments, per-request tool-calling control and built-in OCR and barcode tools. Between them they made it easy to hand a photo to the on-device model, give it those tools, and let it iterate until it is satisfied. The part that is not easy — and the part that decides whether this ships — is that *"until it is satisfied"* is a stopping condition owned by a third party. A model having a bad day with a glare-lit receipt will call the same tool six times, emit a total that does not add up, get told so, and try again. On a server that is a cost line. On a phone it is a spinner, a hot battery, and a user who force-quits.

`BoundedIntakeLoop` is the other half of that feature: a visual-intake pipeline (photo → validated structured record) where **termination, spend and trust are properties of the loop, not of the provider.** Those bounds are *counted*, not clocked — turns, tool calls and context units — and the one thing a caller cannot enforce is spelled out in [Scope, honestly](#scope-honestly) rather than left for you to find.

```
photo ──▶ [ mode ladder: required → allowed → none ]
             │                    │
             │  tool calls        │  draft record
             ▼                    ▼
        [ budget ledger ]    [ invariants: GTIN check digit,
         tool / turn /         totals reconcile, quantities,
         context ceilings      currency, line-item cap ]
             │                    │
             └────────┬───────────┘
                      ▼
         validated record ──── or ────▶ [ deterministic fallback:
         provenance: .model              rebuild from tool evidence ]
                                         provenance: .deterministicFallback
```

**Demo app:** [bounded-intake-loop-kit-demo-app](https://github.com/rajatslakhina/bounded-intake-loop-kit-demo-app) — a SwiftUI app that consumes this package as a version-pinned remote dependency and runs all five scenarios on screen.

---

## Why this matters

Three failure modes show up in every agentic feature that reaches a consumer app, and all three are architecture problems rather than prompting problems:

**1. The loop does not terminate.** The usual bound is "stop when the model says it is done." That is not a bound. Here the ladder descends `required → allowed → none` on a turn counter the model cannot influence; once it reaches `.none`, a tool call is a contract violation that ends the run. Independently, `BudgetLedger` caps turns, tool calls and context units. Either mechanism alone is sufficient, and the tests exercise each in isolation so neither is load-bearing by accident.

**2. Confident output is mistaken for validated output.** A model reading digits off a curved barcode transposes two of them and returns a string that looks exactly like a barcode. The mod-10 GTIN check digit catches that for free, with no network call and without asking the model to grade its own work. Same for money: line items are summed and reconciled against the *printed* total, which is why both are carried separately on `IntakeRecord`.

**3. "The model is unavailable" is treated as an error state.** It is not — the OCR that grounded the model is still sitting right there and still readable. `DeterministicIntake` rebuilds the record from tool evidence alone, and the result carries a `Provenance` so no downstream surface can confuse the two.

---

## Design decisions, and what was rejected

| Decision | Why | Rejected alternative |
|---|---|---|
| **Mode ladder on a turn counter** | Termination becomes a property you can prove by reading `ModeLadder.mode(turnIndex:toolCallsRemaining:)` — it is a pure function of two integers. | A heuristic that stops when the model "seems done" (confidence score, a `finished` flag in the schema). A model that seems done is a model that has not yet had a bad day. |
| **Budget claims are non-suspending actor methods** | Actor isolation only protects state across a suspension if no suspension happens *between the read and the write*. A claim written as "read remaining, `await` something, subtract" lets two turns observe the same remainder and both proceed. | `async` claim methods that consult a remote quota service. Correct-looking, and quietly unbounded. |
| **The coalescing cache is atomic across the suspension too** | `ToolRegistry` keeps an in-flight `Task` per invocation and installs it before its first `await`, so two concurrent callers cannot both decide to run the tool. Without it, "coalescing" is a property of calling serially, not of the registry. | Cache-then-`await`-then-store. It passes every sequential test and fails only under real concurrency — which is why `testConcurrentIdenticalInvocationsStillRunTheToolOnce` races 64 tasks at it. |
| **Two separate ceilings on tool requests** | The budget bounds what gets *run*; `maximumToolRequestsPerTurn` bounds what gets *processed*. A model naming fifty thousand invocations in one turn is unbounded work one layer above where the budget catches it, and the trace reports the two differently — truncation is not a spending decision. | One limit. It makes "we declined 49,996 requests" look like a budget outcome rather than a list nobody read. |
| **Money as `Int` minor units, parsed integer-only** | `"12.99"` never becomes `12.99` as a `Double`, so no representation error is introduced *before* the reconciliation check that exists to detect errors. `Money.string(minorUnits:)` renders without `NumberFormatter` for the same reason. | `Decimal`, which is correct but drags `NSDecimalNumber` bridging into a hot parse path; and `Double`, which forces the reconciliation tolerance to be widened until it stops catching real errors. |
| **Emitting on the first turn is a contract violation** | The first thing in the transcript should be evidence, not a guess. A model that skips grounding has produced an unverifiable record. | Accepting the early emit and validating it. Cheaper, and it silently rewards the failure mode the design exists to prevent. The cost is real and is stated: a provider that gets it right first time is still sent to the fallback. |
| **Coalesced tool repeats cost nothing**, including repeats inside a single turn | Under a budget of four calls, a duplicate is a call the model does not get to spend on something new — and a model in a repetition loop repeats *within* a turn as readily as across turns, so billing per listed invocation rather than per distinct one would quietly break the guarantee (`testDuplicateRequestsWithinOneTurnAreBilledOnce`). | Billing every request. It makes the budget an artifact of model chattiness rather than of real work. |
| **Evidence is deduplicated by invocation** | The direct consequence of the row above: if a free repeat were appended twice, the fallback would reconstruct every line item twice and the reconciliation check would fire against a total that was never wrong. | Appending everything and deduplicating in the parser — the same fix, one layer too late to be obvious. |
| **A closed `ToolPayload` enum, not free-form text** | The deterministic fallback has to rebuild a record with no model in the loop. That is only possible if tool output has a shape code can read. | Passing tool output through as strings, which makes the fallback path impossible and quietly forces the model back onto the critical path. |
| **`IntakeLoop` is a `struct` with no mutable state** | Per-run state is either a local in `run(_:)` — unobservable by any other task — or behind the ledger/registry/trace actors. There is no field on `self` to read on one side of an `await` and write on the other. | An actor holding the run state, which makes reentrancy bugs *possible* and then relies on review to keep them absent. |
| **`ToolCallingMode` is declared here, not imported** | The loop, its tests and the entire termination argument compile and run on a Linux CI box with no model framework present. | Importing the platform framework, which makes the interesting logic untestable anywhere except a Mac with a simulator. |

---

## What's in it

| Type | Role |
|---|---|
| `IntakeLoop` | The loop. One `run(_:) async -> IntakeResult`. |
| `ModeLadder` | `required → allowed → none` as a pure function of turn index and remaining budget. |
| `BudgetLedger` | Actor. Tool-call, turn and context ceilings; every claim is a single non-suspending operation. |
| `IntakeModel` | The provider seam — one method. Adapters for on-device, hosted or scripted models are a conformance away. |
| `GroundingTool` / `ToolRegistry` | Tool dispatch with per-run request coalescing, atomic across suspension, and a bounded cache. |
| `RecordValidator` / `GTIN` | The invariants: check digits, totals reconciliation, quantities, currency, line-item cap. |
| `DeterministicIntake` / `ReceiptTextParser` | The floor. Rebuilds a record from grounding-tool evidence — OCR lines and barcode reads — with no model involved. |
| `IntakeTrace` | Bounded ring buffer of `TraceEvent`, reporting what it dropped rather than silently losing its middle. |
| `IntakeScenarioCatalog` | Five pinned scenarios shared by the tests, the eval harness and the demo app's UI — so a screenshot cannot drift away from a passing test. |
| `IntakeEvalHarness` | Pins provenance, budget and (where it matters) the exact record — re-runnable on device after an OS update. |
| `Saturating` | The one place numeric conversion and accumulation can fail, separately tested. |

---

## How to run it

**The library, on any machine with a Swift 6 toolchain (Linux or macOS):**

```bash
git clone https://github.com/rajatslakhina/bounded-intake-loop-kit.git
cd bounded-intake-loop-kit
# `.build` is removed first because `swift build` on an up-to-date tree compiles
# nothing and still prints "Build complete!" — which is evidence of nothing.
rm -rf .build
swift build -Xswiftc -warnings-as-errors
swift test
```

**The demo app, on a Mac with Xcode 16 or later:**

```bash
git clone https://github.com/rajatslakhina/bounded-intake-loop-kit-demo-app.git
cd bounded-intake-loop-kit-demo-app
open Demo.xcodeproj
```

Let Xcode resolve the remote package, select the `Demo` scheme and any iOS Simulator, then Build & Run. The app runs the loop on first appearance — no tap required.

**Adding it to your own project:**

```swift
.package(url: "https://github.com/rajatslakhina/bounded-intake-loop-kit.git", from: "1.1.0")
```

```swift
let loop = IntakeLoop(
    model: MyOnDeviceAdapter(),                       // or nil — the fallback still reads the photo
    registry: ToolRegistry(tools: [ocrTool, barcodeTool]),
    validator: RecordValidator(policy: .receiptFriendly),
    fallback: DeterministicIntake(currencyCode: "USD"),
    ladder: .default,                                 // 1 required turn, 2 allowed, then none
    budget: .singlePhoto                              // 4 tool calls, 6 turns, 8k context units
)

let result = await loop.run(IntakeAttachment(identifier: "receipt", data: jpeg))

switch result.provenance {
case .model:                 show(result.record, confidence: .high)
case .deterministicFallback: show(result.record, confidence: .needsReview)
case .none:                  askForAnotherPhoto(reason: result.termination.description)
}
```

`result.trace` is the reason a support ticket is answerable. When a user says "it read the wrong total", the trace says whether turn 2 re-requested OCR, whether that was served from cache, and whether the model emitted the same total anyway — which distinguishes a bad OCR line from a bad model.

---

## Tests

**80 XCTest cases, 0 failures.** The suite is written against one rule: *a test that would still pass if the implementation were gutted is worse than no test, because it reads like coverage.* So for every property this README claims, there is a test that feeds in a deliberately broken version and asserts the check **fails**:

- `GTINTests.testRejectsTheCodeALeftWeightedCheckerWouldAccept` computes the check digit the *wrong* way (weights counted from the left, the single most common way to get GS1 wrong), asserts the two disagree on the chosen payload, then asserts the real checker rejects the barcode the broken one would accept.
- `RecordValidatorTests.testOneCentOfDriftIsRejectedUnderStrictPolicy` breaks the fixture by exactly one minor unit. A reconciliation check that compared a value to itself, or to a tolerance derived from the same numbers, passes the happy-path test and fails this one.
- `IntakeTraceTests.testTraceStaysBoundedAndReportsWhatItDropped` pushes 1,000 events into a capacity-8 buffer. An unbounded implementation passes every "does it record?" test and only fails here.
- `IntakeEvalHarnessTests.testTheHarnessFailsWhenAnExpectationIsWrong` feeds the harness three wrong expectations and asserts it reports exactly three failures — otherwise "the eval suite passes" is a statement about the expectations, not about the loop.
- `ConcurrentBudgetClaimTests` races **512 real concurrent tasks** on a ledger with 7 calls to give away, via `withTaskGroup`, and asserts the grants sum to exactly 7. A concurrency test with no concurrent writer proves nothing, so there is one — and `ToolRegistryTests.testConcurrentIdenticalInvocationsStillRunTheToolOnce` does the same for the coalescing cache, against a tool that deliberately suspends before answering so the race window genuinely exists.
- `RecordValidatorTests.testAnIntMinTotalIsRejectedRatherThanTrapping` passes `Int.min` as the printed total — the value that makes `abs(declared - computed)` trap. Every other test in that file passes with or without the guard.

**The headline bound is measured from outside the ledger.** Asserting `budget.toolCallsUsed <= budget.toolCallsLimit` proves nothing: `claimToolCalls` returns `min(request, remaining)`, so the comparison is true by construction however the loop behaves. `IntakeLoopTests.testTheToolBoundIsMeasurableFromOutsideTheLedger` and `testTheTurnBoundIsMeasurableFromOutsideTheLedger` instead count the tool's own entries and the model's own turns — counters the ledger does not own — against a model that asks fifty times.`IntakeEvalHarness` deliberately does not repeat that `used <= limit` comparison either; its tool-call check is falsifiable instead, because `IntakeScenarioCatalog.expectedToolCalls(for:)` is a hand-written number tighter than the ledger's ceiling — the runaway scenario expects `1`, which only holds while coalescing works.

---

## Verification — what was actually executed

| Check | Result |
|---|---|
| `swift build -Xswiftc -warnings-as-errors`, clean tree (`.build` removed first) | Build complete, **0 warnings** — Swift 6.0.3, Linux aarch64 |
| `swift test` | **80 tests, 0 failures** |
| CI, both jobs on the head commit | **Green.** [Actions](https://github.com/rajatslakhina/bounded-intake-loop-kit/actions) runs two jobs: Linux (`swift build -Xswiftc -warnings-as-errors` + `swift test`) and macOS (`xcodebuild build -scheme BoundedIntakeLoop -destination 'generic/platform=iOS Simulator'`). |
| Demo app CI | **Green.** The [demo repo's job](https://github.com/rajatslakhina/bounded-intake-loop-kit-demo-app/actions) runs `xcodebuild -resolvePackageDependencies` and then builds the app, which is what proves the pinned remote package genuinely resolves from GitHub on a clean machine. |
| **Running the app on a Simulator** | **Not done.** The automated run that produced these repos requested computer-use access to Xcode and Simulator three times and was refused each time: *"Computer-use access to \"Xcode 26.3\", \"Simulator\" can't be approved during a scheduled run."* **No screenshots exist**, and there is deliberately no `Demo/Screenshots` directory. "Compiles for an iOS Simulator" and "was launched and used on an iOS Simulator" are two different claims, and only the first one is made here. |

The zero-warnings claim is machine-enforced, not asserted in prose: `-Xswiftc -warnings-as-errors` is in the Linux CI job, so a new warning fails the build.

---

## Scope, honestly

This package deliberately contains **no** `import FoundationModels` and **no** `import Vision`. Those live in the adapter you write on the other side of `IntakeModel` and `GroundingTool`, which is the point of the seam: the termination, budget and validation behaviour is a property of the loop, and it stays true when the provider landscape moves next quarter. The trade-off is real — you write the adapter — and it buys a core that is fully testable in CI on Linux, which is where the interesting properties actually get checked.

**The bounds are counted, not clocked.** `IntakeLoop` bounds turns, tool calls and context units. It does **not** bound wall-clock time, and Swift gives no way to abandon an `await` from the outside, so a conforming `IntakeModel` or `GroundingTool` that hangs and ignores `Task.isCancelled` cannot be stopped by this package. What the loop does provide: `Task.isCancelled` is checked at every turn boundary and terminates the run with `.cancelled` (returning whatever the fallback can build from the evidence gathered so far), and `ToolRegistry` forwards the waiter's cancellation to the shared in-flight task via `withTaskCancellationHandler`, since an unstructured `Task` does not inherit it. Cooperative cancellation is therefore a **requirement on conformers**, stated here rather than papered over with a timeout that could not actually be enforced.

One more consequence worth naming: because the loop must be exercisable without a device model, the demo UI (`IntakeDemoView`) ships **in the library**, not in the demo app. That makes the demo app thin on purpose — it supplies its own configuration and the app shell, and everything it renders comes from a real `IntakeLoop` run.

## License

MIT — see [LICENSE](LICENSE).
