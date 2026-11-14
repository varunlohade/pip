import SwiftUI

// Keyboard cards for NEAR Intents swaps, live previews and receive requests. Kept apart from PayViews so the pay card can
// change without touching these.

/// A swap, or any cross-chain card that is only a preview: what you get, what you spend, slippage, fee, the Intents route,
/// and (on a preview) what is missing. Approve with PIN stays off on a preview: there is no intent and nothing to sign.
struct SwapKeyboardCard: View {
    let panel: PayPanel
    let card: XchainCard
    let approve: () -> Void
    let reject: () -> Void
    let insert: () -> Void
    var openApp: () -> Void = {}

    var body: some View {
        let t = XchainCardText(card)
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if let tag = t.previewTag {
                        Label(tag, systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Color.skyDeep)
                            .accessibilityIdentifier("swapcard.preview")
                    }
                    if panel.requoted, panel.phase != .sent {
                        Label("Price updated. Check it and approve again.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Color.warning)
                    }
                    Text(t.gets).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.Color.text1)
                        .lineLimit(2).minimumScaleFactor(0.7).accessibilityIdentifier("swapcard.gets")
                    Text(t.pays).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.Color.text1)
                        .lineLimit(2).minimumScaleFactor(0.8).accessibilityIdentifier("swapcard.pays")
                    if panel.phase == .sent, let s = panel.swap {
                        status(s)
                    } else {
                        line(t.slippage, id: "swapcard.slippage")
                        line([t.fee, t.rate].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "), id: "swapcard.fee")
                        line(t.intents + (t.path.isEmpty ? "" : ": " + t.path), id: "swapcard.route")
                        line("\(t.eta) \u{00B7} \(t.refund)", id: "swapcard.eta")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
            }
            if panel.phase == .sent {
                if panel.swap?.done == true {
                    Button("Done", action: insert).buttonStyle(SkyPill(height: 46, font: .system(size: 17, weight: .semibold)))
                        .accessibilityIdentifier("swapcard.done")
                }
            } else if case .failed(let text) = panel.phase {
                quiet(text)
            } else {
                if let why = t.blocked { quiet(why).accessibilityIdentifier("swapcard.blocked") }
                if let note = panel.note { quiet(note).accessibilityIdentifier("paycard.note") }
                HStack(spacing: 10) {
                    Button(card.preview ? "Close" : "Reject", action: reject)
                        .buttonStyle(FrostPill(height: 46, font: .system(size: 17, weight: .semibold)))
                        .frame(width: 110)
                        .accessibilityIdentifier("paycard.reject")
                    // The same PIN path as every payment; a preview keeps it off (canApprove is false).
                    ApproveButton(panel: panel, height: 46, approve: approve, openApp: openApp)
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
    }

    private func line(_ text: String, id: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.Color.text2).lineLimit(2).minimumScaleFactor(0.75)
            .accessibilityIdentifier(id)
    }

    @ViewBuilder private func status(_ s: SwapState) -> some View {
        HStack(spacing: 6) {
            switch s {
            case .swapping: ProgressView()
            case .delivered: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Color.success)
            case .refunded, .failed: Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Theme.Color.warning)
            }
            Text(SwapText.line(s)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Color.text1).lineLimit(2)
                .accessibilityIdentifier("swapcard.status")
        }
    }

    private func quiet(_ text: String) -> some View {
        HStack(spacing: 6) {
            Buddy(size: 18)
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.Color.warning).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A receive request or top-up: what the payer pays, what lands in Pip, the deposit address and how long it is open.
/// "Insert request" types the request in the chat (a top-up copies the address). Then the card watches for the money.
struct RequestKeyboardCard: View {
    let panel: PayPanel
    let card: RequestCard
    let share: () -> Void
    let close: () -> Void

    var body: some View {
        let t = RequestText(card)
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if card.preview {
                        Label(XchainCardText.previewTitle, systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Color.skyDeep)
                            .accessibilityIdentifier("requestcard.preview")
                    }
                    Text(t.gets).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.Color.text1)
                        .lineLimit(2).minimumScaleFactor(0.7).accessibilityIdentifier("requestcard.gets")
                    Text(t.pays).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.Color.text1).lineLimit(1)
                        .accessibilityIdentifier("requestcard.pays")
                    if let s = panel.requestStatus {
                        Text(RequestText.status(s)).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(s.status == "received" ? Theme.Color.successInk : Theme.Color.text1).lineLimit(2)
                            .accessibilityIdentifier("requestcard.status")
                    }
                    if let a = card.deposit_address {
                        Text(a).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.Color.text1).lineLimit(2)
                            .textSelection(.enabled).accessibilityIdentifier("requestcard.address")
                    }
                    if let d = card.validUntil {
                        line("Valid until \(RequestText.time(d, timeZone: .current))", id: "requestcard.until")
                    }
                    line(t.slippage, id: "requestcard.slippage")
                    line("Routed by NEAR Intents solvers" + (t.path.isEmpty ? "" : ": " + t.path), id: "requestcard.route")
                    line(t.refund, id: "requestcard.refund")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
            }
            if let why = t.blocked {
                HStack(spacing: 6) {
                    Buddy(size: 18)
                    Text(why).font(.system(size: 13.5)).foregroundStyle(Theme.Color.warning).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("requestcard.blocked")
            }
            if let note = panel.note {
                Text(note).font(.system(size: 13.5)).foregroundStyle(Theme.Color.text2).accessibilityIdentifier("paycard.note")
            }
            HStack(spacing: 10) {
                Button("Close", action: close).buttonStyle(FrostPill(height: 46, font: .system(size: 17, weight: .semibold)))
                    .frame(width: 110)
                    .accessibilityIdentifier("paycard.reject")
                if panel.phase != .sent {
                    Button(card.topUp ? "Copy address" : "Insert request", action: share)
                        .buttonStyle(SkyPill(height: 46, font: .system(size: 17, weight: .semibold)))
                        .disabled(!card.live)
                        .accessibilityIdentifier("requestcard.share")
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
    }

    private func line(_ text: String, id: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.Color.text2).lineLimit(3).minimumScaleFactor(0.8)
            .accessibilityIdentifier(id)
    }
}

/// "Which chain will they pay from?": one chip per chain; a tap adds "on base" to the typed words.
struct ChainChoiceRow: View {
    let prompt: String
    let chains: [ChainChoice]
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(prompt).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Color.text2).lineLimit(1).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chains, id: \.words) { c in
                        Button { pick(c.words) } label: {
                            Text(c.title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.Color.text1)
                                .padding(.horizontal, 11).frame(height: 32).background(FrostFill())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chip.chain.\(c.words)")
                    }
                }
            }
        }
        .padding(.trailing, 6)
    }
}
