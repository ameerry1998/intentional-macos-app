import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

@main
struct ConfidenceGateTests {
    static func main() {
        print("\n🧪 ConfidenceGateTests\n")

        test("relevant=true never enforces off-task (any confidence)") {
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: true, confidence: 99, path: .metadataRelevant),
                false)
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: true, confidence: 10, path: .metadataRelevant),
                false)
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: true, confidence: 100, path: .ocrVerifiedRelevant),
                false)
        }

        test("off-task below threshold (< 50) does NOT enforce — let through") {
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 20, path: .metadataOffTask),
                false,
                "confidence=20 is below threshold — should be let through as unsure")
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 49, path: .metadataOffTask),
                false,
                "confidence=49 is still below threshold")
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 0, path: .metadataOffTask),
                false,
                "confidence=0 (e.g. parse-error fallback) is treated as no signal → let through")
        }

        test("off-task at or above threshold (>= 50) DOES enforce") {
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 50, path: .metadataOffTask),
                true,
                "threshold is inclusive — confidence=50 enforces")
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 80, path: .metadataOffTask),
                true)
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 99, path: .metadataOffTask),
                true)
        }

        test("OCR-verified off-task bypasses confidence threshold") {
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 20, path: .ocrVerifiedOffTask),
                true,
                "OCR pass already resolved uncertainty — trust the verdict regardless of confidence")
            assertEqual(
                ConfidenceGate.shouldEnforceOffTask(relevant: false, confidence: 0, path: .ocrVerifiedOffTask),
                true,
                "even confidence=0 enforces when OCR-verified")
        }

        test("threshold constant is 50 (documented value)") {
            assertEqual(ConfidenceGate.lowConfThreshold, 50)
        }

        print("\n  \(passed) passed, \(failed) failed\n")
        if failed > 0 { exit(1) }
    }
}
