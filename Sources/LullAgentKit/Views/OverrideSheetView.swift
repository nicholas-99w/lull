import LullCore
import SwiftUI

/// Passphrase prompt drawn inside the overlay window (not a real sheet: the
/// overlay sits at shielding level, where separate sheet windows are unreliable).
struct OverrideSheetView: View {
    @ObservedObject var model: AgentModel
    let sheet: OverrideSheetState
    let appearance: Appearance
    @State private var passphrase = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.cancelOverride() }
            VStack(alignment: .leading, spacing: 14) {
                Text(UIStrings.overrideTitle)
                    .font(appearance.font(size: appearance.bodyFontSize * 1.3, weight: .semibold))
                    .foregroundStyle(appearance.titleColor.color(for: scheme))
                    .accessibilityAddTraits(.isHeader)
                Text(UIStrings.overrideMessage)
                    .font(appearance.font(size: appearance.bodyFontSize))
                    .foregroundStyle(appearance.bodyColor.color(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(UIStrings.passphrasePlaceholder, text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .disabled(sheet.busy || sheet.lockedOut)
                    .onSubmit(submit)
                if let message = sheet.message {
                    Text(message)
                        .font(appearance.font(size: appearance.bodyFontSize * 0.9))
                        .foregroundStyle(sheet.isError ? Color.red : appearance.bodyColor.color(for: scheme))
                        .accessibilityAddTraits(.updatesFrequently)
                }
                HStack {
                    if sheet.busy {
                        ProgressView().controlSize(.small)
                        Text(UIStrings.checking).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(UIStrings.cancel) { model.cancelOverride() }
                        .keyboardShortcut(.cancelAction)
                    Button(UIStrings.unlock, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(passphrase.isEmpty || sheet.busy || sheet.lockedOut)
                }
            }
            .padding(24)
            .frame(width: 400)
            .background(appearance.cardBackgroundColor.color(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: min(appearance.cardCornerRadius, 14), style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        }
        .onAppear { focused = true }
        .onChange(of: sheet) { new in
            // Clear the field after each attempt so the passphrase doesn't linger.
            if !new.busy { passphrase = "" }
        }
    }

    private func submit() {
        let p = passphrase
        model.submitOverride(p)
    }
}
