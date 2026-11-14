import SwiftUI

extension PaySetupModel.PINState {
    var line: String {
        switch self {
        case .notSet: "Not set"
        case .on: "On"
        case .locked: "Locked after 5 wrong tries"
        }
    }
}

/// Choose a 6-digit payment PIN, then type it again. Saving asks for Face ID (in the app, where it works).
struct PaymentPINSheet: View {
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Payment PIN").font(Theme.Font.title).foregroundStyle(Theme.Color.text1).padding(.top, 28)
            Text(first == nil ? "Choose 6 digits. The keyboard asks for this PIN when it cannot use Face ID." : "Type the same 6 digits again.")
                .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                ForEach(0..<PayPIN.length, id: \.self) { i in
                    Circle().fill(i < code.count ? Theme.Color.text1 : .clear)
                        .overlay(Circle().strokeBorder(Theme.Color.text2, lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                }
                if busy { ProgressView() }
            }
            .padding(.top, 28)
            .accessibilityIdentifier("pinsetup.dots")
            // The real field is hidden behind the dots; the system number pad types into it.
            SecureField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("pinsetup.field")
                .onChange(of: code) { _, v in typed(v) }
            if let error {
                Text(error).font(.system(size: 15)).foregroundStyle(Theme.Color.warning).padding(.top, 16).accessibilityIdentifier("pinsetup.error")
            }
            Text("Never use your phone passcode or a date. Five wrong tries lock keyboard payments until Face ID in \(AppConfig.displayName).")
                .font(.system(size: 14)).foregroundStyle(Theme.Color.text3).padding(.top, 20).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Not now") { dismiss() }
                .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.text2).frame(maxWidth: .infinity)
                .accessibilityIdentifier("pinsetup.later")
        }
        .padding(.horizontal, Theme.Metric.margin).padding(.bottom, 16)
        .background(Theme.Color.bg.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .presentationDetents([.large])
    }

    private func typed(_ v: String) {
        let digits = String(v.filter(\.isNumber).prefix(PayPIN.length))
        if digits != v { code = digits; return }
        guard digits.count == PayPIN.length, !busy else { return }
        guard let chosen = first else {
            first = digits
            code = ""
            error = nil
            return
        }
        guard chosen == digits else {
            first = nil
            code = ""
            error = "The PINs did not match. Start again."
            return
        }
        busy = true
        Task {
            let failed = await save(digits)
            busy = false
            code = ""
            first = nil
            if let failed { error = failed } else { dismiss() }
        }
    }
}
