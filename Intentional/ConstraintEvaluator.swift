//
//  ConstraintEvaluator.swift
//  Intentional
//
//  Pure-function typed constraint evaluator. Produces the minimum-change
//  correction for ratchet-up-only enforcement. See
//  docs/superpowers/specs/2026-04-23-content-safety-lockdown-design.md §5.6.
//

import Foundation

enum Constraint: Equatable {
    case mustBeTrue
    case mustBeFalse
    case minValue(Double)
    case mustIncludeAll([String])
    case unknown(String)
}

enum ConstraintResult: Equatable {
    case satisfied
    case violated(correction: Any)
    case cannotAutoCorrect

    static func == (lhs: ConstraintResult, rhs: ConstraintResult) -> Bool {
        switch (lhs, rhs) {
        case (.satisfied, .satisfied), (.cannotAutoCorrect, .cannotAutoCorrect):
            return true
        case (.violated(let a), .violated(let b)):
            return String(describing: a) == String(describing: b)
        default:
            return false
        }
    }
}

enum ConstraintEvaluator {
    static func evaluate(key: String, constraint: Constraint, currentValue: Any?) -> ConstraintResult {
        switch constraint {
        case .mustBeTrue:
            if let b = currentValue as? Bool, b == true { return .satisfied }
            return .violated(correction: true)

        case .mustBeFalse:
            if let b = currentValue as? Bool, b == false { return .satisfied }
            return .violated(correction: false)

        case .minValue(let floor):
            let current: Double? = {
                if let d = currentValue as? Double { return d }
                if let i = currentValue as? Int { return Double(i) }
                return nil
            }()
            if let c = current, c >= floor { return .satisfied }
            return .violated(correction: floor)

        case .mustIncludeAll(let required):
            let current = (currentValue as? [String]) ?? []
            let missing = required.filter { !current.contains($0) }
            if missing.isEmpty { return .satisfied }
            return .violated(correction: Array(Set(current + required)))

        case .unknown:
            return .cannotAutoCorrect
        }
    }

    /// Parse a JSON constraint spec from the backend blob into a `Constraint`.
    static func parse(_ spec: [String: Any]) -> Constraint {
        let type = spec["type"] as? String ?? ""
        switch type {
        case "must_be_true":       return .mustBeTrue
        case "must_be_false":      return .mustBeFalse
        case "min_value":
            let v = (spec["value"] as? Double) ?? Double(spec["value"] as? Int ?? 0)
            return .minValue(v)
        case "must_include_all":
            let values = spec["values"] as? [String] ?? []
            return .mustIncludeAll(values)
        default:
            return .unknown(type)
        }
    }
}
