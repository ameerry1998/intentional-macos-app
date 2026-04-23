import XCTest
@testable import Intentional

final class ConstraintEvaluatorTests: XCTestCase {

    func test_mustBeTrue_satisfied_when_true() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: true)
        XCTAssertEqual(result, .satisfied)
    }

    func test_mustBeTrue_violated_corrects_to_true() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: false)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Bool, true)
    }

    func test_mustBeTrue_violated_when_missing() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .mustBeTrue, currentValue: nil)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Bool, true)
    }

    func test_minValue_satisfied_when_equal() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 7)
        XCTAssertEqual(result, .satisfied)
    }

    func test_minValue_satisfied_when_greater() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 10)
        XCTAssertEqual(result, .satisfied)
    }

    func test_minValue_violated_corrects_to_floor() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .minValue(7), currentValue: 3)
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        XCTAssertEqual(correction as? Double, 7)
    }

    func test_mustIncludeAll_satisfied_when_superset() {
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a", "b"]),
            currentValue: ["a", "b", "c"]
        )
        XCTAssertEqual(result, .satisfied)
    }

    func test_mustIncludeAll_violated_corrects_by_adding_missing() {
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a", "b", "c"]),
            currentValue: ["a"]
        )
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        let out = (correction as? [String])?.sorted()
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    func test_mustIncludeAll_violated_preserves_user_extras() {
        let result = ConstraintEvaluator.evaluate(
            key: "sites",
            constraint: .mustIncludeAll(["a"]),
            currentValue: ["x", "y"]
        )
        guard case .violated(let correction) = result else { XCTFail("expected violation"); return }
        let out = (correction as? [String])?.sorted()
        XCTAssertEqual(out, ["a", "x", "y"])
    }

    func test_unknown_constraint_cannot_auto_correct() {
        let result = ConstraintEvaluator.evaluate(key: "x", constraint: .unknown("future_type"), currentValue: nil)
        XCTAssertEqual(result, .cannotAutoCorrect)
    }
}
