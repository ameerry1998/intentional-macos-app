import SwiftUI

// MARK: - View Model

class BedtimeOverlayViewModel: ObservableObject {
    @Published var countdownSeconds: Int = 180  // 3 minutes
    @Published var snoozeAvailable: Bool = true
    @Published var showCodeEntry: Bool = false
    @Published var codeText: String = ""
    @Published var codeError: String = ""

    var onSnooze: (() -> Void)?
    var onSleepNow: (() -> Void)?
    var onCodeSubmit: ((String) -> Void)?

    var countdownFormatted: String {
        let min = countdownSeconds / 60
        let sec = countdownSeconds % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - Bedtime Overlay View

struct BedtimeOverlayView: View {
    @ObservedObject var viewModel: BedtimeOverlayViewModel

    // Near-black dark palette — sleep-friendly, NOT glassmorphism
    private let bgTop = Color(white: 0.04)
    private let bgBottom = Color(white: 0.02)
    private let headingColor = Color(white: 0.7)
    private let subtitleColor = Color(white: 0.4)
    private let linkColor = Color(white: 0.35)
    private let buttonBg = Color(white: 0.10)
    private let buttonBorder = Color(white: 0.2)
    private let buttonTextDim = Color(white: 0.6)
    private let buttonTextBright = Color(white: 0.8)
    private let countdownColor = Color(white: 0.5)
    private let errorColor = Color(red: 0.8, green: 0.2, blue: 0.2).opacity(0.7)

    var body: some View {
        ZStack {
            // Full-screen near-black gradient — no blur, no glass, just darkness
            LinearGradient(
                colors: [bgTop, bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if viewModel.showCodeEntry {
                    codeEntryContent
                } else if viewModel.snoozeAvailable {
                    snoozeAvailableContent
                } else {
                    countdownContent
                }

                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Mode 1: Snooze Available (first lockout)

    @ViewBuilder
    private var snoozeAvailableContent: some View {
        VStack(spacing: 0) {
            Text("\u{1F319}")
                .font(.system(size: 64))
                .padding(.bottom, 20)

            Text("Bedtime")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(headingColor)
                .padding(.bottom, 8)

            Text("Time to sleep.")
                .font(.system(size: 17))
                .foregroundColor(subtitleColor)
                .padding(.bottom, 40)

            // Snooze button
            Button(action: { viewModel.onSnooze?() }) {
                Text("Snooze 10 min")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(buttonTextDim)
                    .frame(width: 220)
                    .padding(.vertical, 14)
                    .background(buttonBg)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(buttonBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            // Sleep Now button
            Button(action: { viewModel.onSleepNow?() }) {
                Text("Sleep Now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(buttonTextBright)
                    .frame(width: 220)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.12))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(buttonBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)

            // Partner code link
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showCodeEntry = true
                }
            }) {
                Text("Enter Partner Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(linkColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Mode 2: No Snooze (countdown to sleep)

    @ViewBuilder
    private var countdownContent: some View {
        VStack(spacing: 0) {
            Text("\u{1F319}")
                .font(.system(size: 64))
                .padding(.bottom, 20)

            Text("Bedtime")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(headingColor)
                .padding(.bottom, 8)

            Text("Mac will sleep in")
                .font(.system(size: 17))
                .foregroundColor(subtitleColor)
                .padding(.bottom, 16)

            // Large countdown timer
            Text(viewModel.countdownFormatted)
                .font(.system(size: 72, weight: .light, design: .monospaced))
                .foregroundColor(countdownColor)
                .padding(.bottom, 32)

            // Sleep Now button
            Button(action: { viewModel.onSleepNow?() }) {
                Text("Sleep Now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(buttonTextBright)
                    .frame(width: 220)
                    .padding(.vertical, 14)
                    .background(Color(white: 0.12))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(buttonBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)

            // Partner code link
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showCodeEntry = true
                }
            }) {
                Text("Enter Partner Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(linkColor)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Code Entry Mode

    @ViewBuilder
    private var codeEntryContent: some View {
        VStack(spacing: 0) {
            Text("\u{1F319}")
                .font(.system(size: 48))
                .padding(.bottom, 16)

            Text("Partner Code")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(headingColor)
                .padding(.bottom, 24)

            // 6-digit code field
            TextField("000000", text: $viewModel.codeText)
                .textFieldStyle(.plain)
                .font(.system(size: 32, weight: .medium, design: .monospaced))
                .foregroundColor(headingColor)
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color(white: 0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(buttonBorder, lineWidth: 1)
                )
                .onChange(of: viewModel.codeText) { _, newValue in
                    // Limit to 6 digits
                    let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                    if filtered != newValue {
                        viewModel.codeText = filtered
                    }
                }
                .padding(.bottom, 8)

            // Error message
            if !viewModel.codeError.isEmpty {
                Text(viewModel.codeError)
                    .font(.system(size: 13))
                    .foregroundColor(errorColor)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 21) // Reserve space for error
            }

            Spacer().frame(height: 16)

            // Cancel + Submit buttons
            HStack(spacing: 16) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showCodeEntry = false
                        viewModel.codeText = ""
                        viewModel.codeError = ""
                    }
                }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(buttonTextDim)
                        .frame(width: 100)
                        .padding(.vertical, 12)
                        .background(buttonBg)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(buttonBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    viewModel.onCodeSubmit?(viewModel.codeText)
                }) {
                    Text("Submit")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.codeText.count == 6 ? buttonTextBright : buttonTextDim)
                        .frame(width: 100)
                        .padding(.vertical, 12)
                        .background(viewModel.codeText.count == 6 ? Color(white: 0.12) : buttonBg)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(buttonBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.codeText.count != 6)
            }
        }
    }
}
