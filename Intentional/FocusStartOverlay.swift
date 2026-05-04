import SwiftUI

// MARK: - View Model

class FocusStartOverlayViewModel: ObservableObject {
    @Published var availableProfiles: [BlockingProfile] = []
    @Published var selectedProfileIds: Set<UUID> = []
    @Published var intentionText: String = ""
    @Published var aiScoringEnabled: Bool = false
    @Published var isPuckTriggered: Bool = false
    @Published var showPlanner: Bool = false

    var onStartFocus: ((_ profileIds: [UUID], _ intention: String?, _ aiEnabled: Bool) -> Void)?
    var onCancel: (() -> Void)?

    var canStart: Bool {
        !selectedProfileIds.isEmpty || !intentionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// FlowLayout is defined in InterventionOverlayController.swift — reused here

// MARK: - Focus Start Overlay View

struct FocusStartOverlayView: View {
    @ObservedObject var viewModel: FocusStartOverlayViewModel

    // Dark palette — matches the rest of the bedtime / focus surfaces
    private let bgTop = Color(white: 0.06)
    private let bgBottom = Color(white: 0.03)
    private let headingColor = Color(white: 0.75)
    private let subtitleColor = Color(white: 0.4)
    private let sectionLabelColor = Color(white: 0.4)
    private let chipSelectedBg = Color.blue.opacity(0.15)
    private let chipSelectedBorder = Color.blue.opacity(0.6)
    private let chipSelectedText = Color.blue
    private let chipUnselectedBg = Color(white: 0.1)
    private let chipUnselectedBorder = Color(white: 0.2)
    private let chipUnselectedText = Color(white: 0.6)
    private let fieldBg = Color(white: 0.08)
    private let fieldText = Color(white: 0.8)
    private let buttonBg = Color(white: 0.10)
    private let buttonBorder = Color(white: 0.2)
    private let buttonTextDim = Color(white: 0.6)
    private let accentBlue = Color.blue

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [bgTop, bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if viewModel.isPuckTriggered && !viewModel.showPlanner {
                    puckModeContent
                } else {
                    plannerModeContent
                }

                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Puck Mode

    @ViewBuilder
    private var puckModeContent: some View {
        VStack(spacing: 0) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 56))
                .foregroundColor(headingColor)
                .padding(.bottom, 20)

            Text("Distractions Blocked")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(headingColor)
                .padding(.bottom, 8)

            Text("Your default blocking list is active.")
                .font(.system(size: 17))
                .foregroundColor(subtitleColor)
                .padding(.bottom, 40)

            // Just Block Distractions button
            Button(action: {
                let profileIds = Array(viewModel.selectedProfileIds)
                viewModel.onStartFocus?(profileIds, nil, false)
            }) {
                Text("Just Block Distractions")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 260)
                    .padding(.vertical, 14)
                    .background(accentBlue)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)

            // Plan My Session link
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showPlanner = true
                }
            }) {
                Text("Plan My Session")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(subtitleColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Planner Mode

    @ViewBuilder
    private var plannerModeContent: some View {
        VStack(spacing: 0) {
            Text("What are you working on?")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(headingColor)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)

            // BLOCKING PROFILES section
            VStack(alignment: .leading, spacing: 12) {
                Text("BLOCKING PROFILES")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(sectionLabelColor)

                FlowLayout(spacing: 8) {
                    ForEach(viewModel.availableProfiles) { profile in
                        profileChip(profile: profile)
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.bottom, 28)

            // AI FOCUS section
            VStack(alignment: .leading, spacing: 12) {
                Text("AI FOCUS (OPTIONAL)")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(sectionLabelColor)

                TextField("Describe your task for AI scoring...", text: $viewModel.intentionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(fieldText)
                    .padding(14)
                    .background(fieldBg)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(white: 0.15), lineWidth: 1)
                    )
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.bottom, 36)

            // Bottom buttons
            HStack(spacing: 16) {
                // Free Time button (only when NOT Puck-triggered)
                if !viewModel.isPuckTriggered {
                    Button(action: {
                        viewModel.onCancel?() // Free time = dismiss without creating session
                    }) {
                        Text("Free Time")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(buttonTextDim)
                            .frame(width: 110)
                            .padding(.vertical, 14)
                            .background(buttonBg)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(buttonBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Cancel / Back button
                Button(action: {
                    if viewModel.isPuckTriggered && viewModel.showPlanner {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.showPlanner = false
                        }
                    } else {
                        viewModel.onCancel?()
                    }
                }) {
                    Text(viewModel.isPuckTriggered && viewModel.showPlanner ? "Back" : "Cancel")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(white: 0.3))
                        .frame(width: 80)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                // Start Focus button
                Button(action: {
                    let profileIds = Array(viewModel.selectedProfileIds)
                    let intention = viewModel.intentionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.onStartFocus?(
                        profileIds,
                        intention.isEmpty ? nil : intention,
                        viewModel.aiScoringEnabled
                    )
                }) {
                    Text("Start Focus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(viewModel.canStart ? .white : buttonTextDim)
                        .frame(width: 160)
                        .padding(.vertical, 14)
                        .background(viewModel.canStart ? accentBlue : Color(white: 0.12))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(viewModel.canStart ? accentBlue : buttonBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canStart)
            }
        }
    }

    // MARK: - Profile Chip

    @ViewBuilder
    private func profileChip(profile: BlockingProfile) -> some View {
        let isSelected = viewModel.selectedProfileIds.contains(profile.id)

        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isSelected {
                    viewModel.selectedProfileIds.remove(profile.id)
                } else {
                    viewModel.selectedProfileIds.insert(profile.id)
                }
            }
        }) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(chipSelectedText)
                }
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? chipSelectedText : chipUnselectedText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? chipSelectedBg : chipUnselectedBg)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? chipSelectedBorder : chipUnselectedBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
