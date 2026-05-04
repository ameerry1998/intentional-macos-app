// Intentional/BedtimeUnlockRequestView.swift
// Mac dashboard view: ask the partner to unlock bedtime early.
//
// Replaces the iPhone-only flow with parity on Mac. Slider has 5 snap
// points (15 / 30 / 60 / 120 / -1 = until wake) matching the iPhone
// design and the backend Pydantic validator. Reasons + optional note
// are still captured below the slider.
//
// Once-per-night: backend returns 409 if a verified row has
// released_until > now. The view surfaces that as
// `BedtimeUnlockError.alreadyUsed` with the locked-out copy.

import SwiftUI

/// Spec 3 (May 2026): kind discriminator so the same view handles both the
/// existing bedtime-unlock flow and the new Strict-step-down strictness flow.
enum UnlockRequestKind: Equatable {
    case bedtime
    case intentionStrictness(intentionId: UUID, toPreset: StrictnessPreset, intentionName: String)

    var titleText: String {
        switch self {
        case .bedtime: return "Ask your partner to unlock early"
        case .intentionStrictness(_, let to, let name):
            return "Ask your partner to soften \(name) → \(to.rawValue.capitalized)"
        }
    }

    var captionText: String {
        switch self {
        case .bedtime: return "They'll get an email with a 6-digit code."
        case .intentionStrictness:
            return "They'll get an email with a 6-digit code. Once entered, the change applies immediately."
        }
    }
}

struct BedtimeUnlockRequestView: View {
    @Environment(\.dismiss) private var dismiss

    let kind: UnlockRequestKind

    init(kind: UnlockRequestKind = .bedtime) {
        self.kind = kind
    }

    @State private var durationIndex: Int = 1  // default 30 min
    @State private var reason: String = "Other"
    @State private var note: String = ""
    @State private var sending = false
    @State private var sentToPartner: String?
    @State private var errorText: String?

    /// Snap points. -1 = "until wake alarm".
    private let durationValues: [Int] = [15, 30, 60, 120, -1]
    private var selectedDuration: Int { durationValues[durationIndex] }
    private let reasons = ["Emergency", "Travel", "Work", "Other"]

    private let bedtimeAccent = Color(red: 0.70, green: 0.53, blue: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.titleText)
                    .font(.title3.weight(.semibold))
                Text(kind.captionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if case .bedtime = kind {
                durationSelector
            }
            reasonPicker
            noteField

            if let sentToPartner {
                Label("Code sent to \(sentToPartner)", systemImage: "envelope.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    send()
                } label: {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send unlock request")
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(bedtimeAccent)
                .disabled(sending || sentToPartner != nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - Subviews

    private var durationSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STAY UP FOR")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<durationValues.count, id: \.self) { i in
                    Button {
                        durationIndex = i
                    } label: {
                        Text(label(for: durationValues[i]))
                            .font(.system(
                                size: 12,
                                weight: durationIndex == i ? .semibold : .regular
                            ))
                            .foregroundStyle(durationIndex == i ? bedtimeAccent : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(durationIndex == i
                                        ? bedtimeAccent.opacity(0.18)
                                        : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        durationIndex == i
                                            ? bedtimeAccent.opacity(0.5)
                                            : Color.gray.opacity(0.25),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var reasonPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("REASON")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Picker("Reason", selection: $reason) {
                ForEach(reasons, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTE (OPTIONAL)")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            TextField("e.g. flight at 6am", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Helpers

    private func label(for minutes: Int) -> String {
        switch minutes {
        case 15:  return "15 min"
        case 30:  return "30 min"
        case 60:  return "1 hour"
        case 120: return "2 hours"
        case -1:  return "Until wake"
        default:  return "\(minutes) min"
        }
    }

    private func send() {
        sending = true
        errorText = nil
        switch kind {
        case .bedtime:
            sendBedtime()
        case .intentionStrictness(let intentionId, let toPreset, _):
            sendIntentionStrictness(intentionId: intentionId, toPreset: toPreset)
        }
    }

    private func sendBedtime() {
        let backend = (NSApp.delegate as? AppDelegate)?.backendClient
        guard let backend else {
            errorText = "Backend client not available."
            sending = false
            return
        }
        Task {
            do {
                let result = try await backend.bedtimeUnlockRequest(
                    durationMinutes: selectedDuration,
                    reason: reason,
                    note: note.isEmpty ? nil : note
                )
                await MainActor.run {
                    sentToPartner = result.partnerEmail
                    sending = false
                }
            } catch let err as BackendClient.BedtimeUnlockError {
                await MainActor.run {
                    errorText = err.errorDescription ?? "Unknown error"
                    sending = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    sending = false
                }
            }
        }
    }

    private func sendIntentionStrictness(intentionId: UUID, toPreset: StrictnessPreset) {
        let backend = (NSApp.delegate as? AppDelegate)?.backendClient
        guard let backend else {
            errorText = "Backend client not available."
            sending = false
            return
        }
        Task {
            do {
                let result = try await backend.requestIntentionStrictnessUnlock(
                    intentionId: intentionId,
                    toPreset: toPreset,
                    reason: reason,
                    note: note.isEmpty ? nil : note
                )
                await MainActor.run {
                    sentToPartner = result.sentTo
                    sending = false
                }
            } catch let err as BackendClient.StrictnessUpdateError {
                await MainActor.run {
                    errorText = err.errorDescription ?? "Unknown error"
                    sending = false
                }
            } catch {
                await MainActor.run {
                    errorText = error.localizedDescription
                    sending = false
                }
            }
        }
    }
}
