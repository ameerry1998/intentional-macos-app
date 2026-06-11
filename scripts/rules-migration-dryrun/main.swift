// rules-migration-dryrun — R6 rehearsal driver.
//
// Compiles the app's REAL planning logic (RulesMigrationPlan.swift) against
// COPIES of the user's data files and prints the would-be rules without
// POSTing anything. Build + run:
//
//   mkdir -p /tmp/rules-dryrun-input
//   cp ~/Library/Application\ Support/Intentional/blocking_profiles.json /tmp/rules-dryrun-input/
//   cp ~/Library/Application\ Support/Intentional/always_allowed.json   /tmp/rules-dryrun-input/
//   DEVICE_ID=$(defaults read com.arayan.intentional deviceId)
//   curl -s -H "X-Device-ID: $DEVICE_ID" https://api.intentional.social/always_blocked > /tmp/rules-dryrun-input/always_blocked.json
//   curl -s -H "X-Device-ID: $DEVICE_ID" https://api.intentional.social/distractions  > /tmp/rules-dryrun-input/distractions.json
//   curl -s -H "X-Device-ID: $DEVICE_ID" https://api.intentional.social/rules         > /tmp/rules-dryrun-input/rules.json
//   swiftc -o /tmp/rules-dryrun \
//     Intentional/BlockingProfileManager.swift Intentional/AlwaysAllowedList.swift \
//     Intentional/Rule.swift Intentional/EnforcementCache.swift \
//     Intentional/RulesMigrationPlan.swift scripts/rules-migration-dryrun/main.swift
//   /tmp/rules-dryrun /tmp/rules-dryrun-input

import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: rules-dryrun <input-dir>")
    exit(1)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)

func load(_ name: String) -> Data? {
    try? Data(contentsOf: dir.appendingPathComponent(name))
}

// Sources (each optional — missing file = empty source, same as the app).
let profiles: [BlockingProfile] = load("blocking_profiles.json")
    .flatMap { try? JSONDecoder().decode([BlockingProfile].self, from: $0) } ?? []
let alwaysAllowed: AlwaysAllowedList? = load("always_allowed.json")
    .flatMap { try? JSONDecoder().decode(AlwaysAllowedList.self, from: $0) }

struct AppListResponse: Codable {
    struct Entry: Codable { let app_identifier: String }
    let apps: [Entry]
}
func appList(_ name: String) -> [String] {
    load(name).flatMap { try? JSONDecoder().decode(AppListResponse.self, from: $0) }?
        .apps.map { $0.app_identifier } ?? []
}
let backendBlocked = appList("always_blocked.json")
let backendDistractions = appList("distractions.json")

let existing: [Rule] = load("rules.json")
    .flatMap { try? JSONDecoder().decode(RuleListResponse.self, from: $0) }?.rules ?? []
let existingKeys = Set(existing.map {
    RulesMigrationPlan.PlannedRule.key(kind: $0.targetKind, target: $0.target)
})

print("=== RulesMigration DRY RUN (standalone driver, \(Date())) ===")
print("Inputs: \(profiles.count) profiles " +
      "(\(profiles.map { "\"\($0.name)\" enabled=\($0.enabled) domains=\($0.blockedDomains.count) apps=\($0.blockedAppBundleIds.count)" }.joined(separator: "; "))), " +
      "always_allowed=\(alwaysAllowed.map { "\($0.bundleIds.count) apps + \($0.domains.count) domains" } ?? "missing"), " +
      "backend always_blocked=\(backendBlocked.count), backend distractions=\(backendDistractions.count), " +
      "existing backend rules=\(existingKeys.count)")
print("")

let plan = RulesMigrationPlan.build(profiles: profiles,
                                    alwaysAllowed: alwaysAllowed,
                                    backendAlwaysBlocked: backendBlocked,
                                    backendDistractions: backendDistractions,
                                    existingRuleKeys: existingKeys)
print(RulesMigrationPlan.describe(plan))
print("")
print("=== NOTHING was POSTed, renamed, or mutated. ===")
