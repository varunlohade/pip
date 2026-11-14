import SwiftUI

// Every Pip Pay and Private AI visual, in one file (design A), so a switch to design B changes only this file.
// The views take plain values and closures; the logic lives in KeyboardModel+Pay and App/PayApproval.

/// "Private AI · verified on NEAR", or "Private AI" when the TEE answered but its attestation was not checked.
struct PrivacyMarkView: View {
    let mark: PrivacyMark
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mark == .verified ? "checkmark.shield.fill" : "lock.shield")
                .foregroundStyle(Theme.Color.success)
            Text("Private AI").fontWeight(.semibold).foregroundStyle(Theme.Color.text1)
            if mark == .verified { Text("\u{00B7} verified on NEAR").foregroundStyle(Theme.Color.text2) }
        }
        .font(.system(size: size))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("privacy.mark")
    }
}

// MARK: keyboard

/// The keyboard bar: the pay chip (A-1) or the sent line with Insert (A-3).
struct PayBarRow: View {
    let item: BarItems.Item
    let perform: (BarItems.Action) -> Void

    var body: some View {
        if item.id == "paid" { sent } else { chip }
    }

    private var chip: some View {
        Button { perform(.pay) } label: {
            HStack(spacing: 8) {
                Buddy(size: 22)
                Text(item.title).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Theme.Color.text1)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\u{00B7}").foregroundStyle(Theme.Color.text3)
                Text(item.detail ?? "").font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.Color.skyDeep)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(.white).shadow(color: .black.opacity(0.12), radius: 1.5, y: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(item.detail ?? "")")
        .accessibilityIdentifier("chip.pay")
        .padding(.horizontal, 4)
    }

    private var sent: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.Color.success)
            Text(item.title).font(.system(size: 15.5, weight: .medium)).foregroundStyle(Theme.Color.text1)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Button("Insert") { perform(.insertPaid) }
                .buttonStyle(SkyPill(height: 36, font: .system(size: 16, weight: .semibold), fullWidth: false))
                .fixedSize()
                .accessibilityIdentifier("chip.paid.insert")
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chip.paid")
    }
}

// MARK: app: approval card (A-2) and sent state

struct PayApprovalCard: View {
    let intent: PayIntent?
    let wallet: PayWallet?
    let mark: PrivacyMark?
    let phase: ApprovalPhase
    let note: String?
    let approve: () -> Void
    let reject: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Buddy(size: 30)
                Text("Pip Pay").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Color.text2)
                        .frame(width: 36, height: 36).background(Theme.Color.panel, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("pay.close")
            }
            .padding(.bottom, 28)
            if let i = intent {
                switch phase {
                case .sent: sent(i)
                default: details(i)
                }
            } else if case .failed(let line) = phase {
                Text(line).font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
        .background(Theme.Color.bg)
    }

    private func amount(_ i: PayIntent) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: i.token == "USDC" ? "dollarsign.circle.fill" : "n.circle.fill")
                .font(.system(size: 50)).foregroundStyle(i.token == "USDC" ? Color(hex: 0x2775CA) : Theme.Color.text1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(i.amount).font(.system(size: 64, weight: .bold)).foregroundStyle(Theme.Color.text1)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(i.token).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                }
                if i.token == "USDC", let v = Double(i.amount) {
                    Text("About \(v.formatted(.currency(code: "USD")))").font(.system(size: 18)).foregroundStyle(Theme.Color.text3)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pay.amount")
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).font(.system(size: 17)).foregroundStyle(Theme.Color.text3).frame(width: 96, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 54)
    }

    private func details(_ i: PayIntent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            amount(i).padding(.bottom, 24)
            row("To") {
                HStack(spacing: 10) {
                    Text(String(i.recipient.prefix(2)).uppercased()).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Theme.Color.text3.opacity(0.7), in: Circle())
                    Text(i.recipient).font(.system(size: 18)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            row("Network") {
                HStack(spacing: 7) {
                    Text("N").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white).frame(width: 22, height: 22).background(.black, in: Circle())
                    Text("NEAR \(i.network)").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.text1)
                }
                .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                .background(Theme.Color.panel, in: Capsule()).overlay(Capsule().strokeBorder(Theme.Color.hairline))
                .accessibilityIdentifier("pay.network")
            }
            row("Fee") { Text("Under 0.001 NEAR").font(.system(size: 18)).foregroundStyle(Theme.Color.text1) }
            row("From") {
                HStack(spacing: 10) {
                    Text(wallet?.account_id ?? "Your Pip wallet").font(.system(size: 17)).foregroundStyle(Theme.Color.text1)
                        .lineLimit(1).truncationMode(.middle)
                    if let left = wallet?.balances?[i.token] {
                        Text("\(left) left").font(.system(size: 17)).foregroundStyle(Theme.Color.text3).fixedSize()
                    }
                }
            }
            .padding(.bottom, 16)
            if let note {
                Text(note).font(.system(size: 15)).foregroundStyle(Theme.Color.warning).padding(.bottom, 10)
                    .accessibilityIdentifier("pay.note")
            }
            if phase == .rejected {
                Text("Declined. Nothing was sent.").font(Theme.Font.bodyMedium).foregroundStyle(Theme.Color.text2)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .accessibilityIdentifier("pay.rejected")
            } else if case .failed(let line) = phase {
                Text(line).font(Theme.Font.bodyMedium).foregroundStyle(Theme.Color.text2).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(spacing: 12) {
                    Button("Reject", action: reject)
                        .buttonStyle(FrostPill(height: 62, font: .system(size: 20, weight: .semibold)))
                        .frame(width: 140)
                        .accessibilityIdentifier("pay.reject")
                    Button(action: approve) {
                        HStack(spacing: 10) {
                            if phase == .approving { ProgressView().tint(.white) } else { Image(systemName: "faceid") }
                            Text("Approve")
                        }
                    }
                    .buttonStyle(SkyPill(height: 62, font: .system(size: 20, weight: .semibold)))
                    .accessibilityIdentifier("pay.approve")
                }
                .disabled(phase != .ready)
            }
            if let mark { PrivacyMarkView(mark: mark, size: 15).frame(maxWidth: .infinity).padding(.top, 20) }
        }
    }

    private func sent(_ i: PayIntent) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(Theme.Color.success)
                .padding(.top, 24)
            Text("Sent \(i.amount) \(i.token)").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.Color.text1)
                .accessibilityIdentifier("pay.sent")
            Text("to \(i.recipient) on NEAR \(i.network)").font(.system(size: 17)).foregroundStyle(Theme.Color.text2)
            if let s = i.explorer_url, let url = URL(string: s) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Text(Self.shortTx(s)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.skyDeep)
                }
                .accessibilityIdentifier("pay.tx")
            }
            Text("Back in your chat, tap Insert on the keyboard to send the receipt.")
                .font(.system(size: 15)).foregroundStyle(Theme.Color.text3).multilineTextAlignment(.center).padding(.top, 8)
            Button("Done", action: close).buttonStyle(SkyPill(height: 58)).padding(.top, 12)
                .accessibilityIdentifier("pay.done")
        }
        .frame(maxWidth: .infinity)
    }

    /// "testnet.nearblocks.io/txns/7Hq2…kP4"
    static func shortTx(_ url: String) -> String {
        let bare = url.replacingOccurrences(of: "https://", with: "")
        guard let slash = bare.lastIndex(of: "/") else { return bare }
        let hash = bare[bare.index(after: slash)...]
        return hash.count > 10 ? bare[...slash] + hash.prefix(4) + "\u{2026}" + hash.suffix(3) : bare
    }
}

typealias ApprovalPhase = PayPhase

/// Where the approval card is. The app's ApprovalModel drives it.
enum PayPhase: Equatable { case loading, ready, approving, sent, rejected, failed(String) }

// MARK: app: Home wallet row and the Private AI proof

struct WalletCard: View {
    let wallet: PayWallet?
    let failed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("N").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white).frame(width: 36, height: 36).background(.black, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Wallet \u{00B7} \(wallet.map { "NEAR \($0.network)" } ?? PayNetwork.label)").font(Theme.Font.label).foregroundStyle(Theme.Color.text3)
                Text(wallet?.account_id ?? (failed ? "Wallet not ready. Pull to try again." : "Getting your wallet\u{2026}"))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.text1).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let b = wallet?.balances {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(b["USDC"] ?? "0") USDC").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                    Text("\(b["NEAR"] ?? "0") NEAR").font(.system(size: 13)).foregroundStyle(Theme.Color.text3)
                }
                .fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .ringCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.wallet")
    }
}

struct PrivateAIRow: View {
    var body: some View {
        HStack {
            PrivacyMarkView(mark: .verified, size: 14)
            Spacer()
            Text("See proof").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Color.skyDeep)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.text3)
        }
        .padding(.horizontal, 16).frame(height: 48)
        .ringCard()
    }
}

struct AIProofView: View {
    let proof: AIAttestation?
    let failed: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Private AI").font(Theme.Font.title).foregroundStyle(Theme.Color.text1)
                if let p = proof {
                    status(p)
                    if let models = p.models, !models.isEmpty {
                        section("Models we checked") {
                            ForEach(models, id: \.model) { m in
                                line(m.ok ? "checkmark.circle.fill" : "xmark.circle.fill", m.ok ? Theme.Color.success : Theme.Color.warning,
                                     m.model + (m.ok ? "" : ": \(m.failure ?? "check failed")"))
                            }
                            if let s = p.last_signature {
                                line(s.ok ? "signature" : "xmark.circle.fill", s.ok ? Theme.Color.success : Theme.Color.warning,
                                     s.ok ? "Last reply signed by the checked model key" : "Last reply signature: \(s.failure ?? "failed")")
                            }
                        }
                    }
                    if let m = p.method, !m.isEmpty {
                        section("What we check") { ForEach(m, id: \.self) { line("checkmark", Theme.Color.success, $0) } }
                    }
                    if let n = p.not_checked, !n.isEmpty {
                        section("What we don't check yet") { ForEach(n, id: \.self) { line("minus.circle", Theme.Color.text3, $0) } }
                            .accessibilityIdentifier("proof.notChecked")
                    }
                    if let v = p.verify_url, let url = URL(string: v) {
                        Link("Check it yourself on NEAR AI", destination: url).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.skyDeep)
                    }
                } else if failed {
                    Text("Could not load the proof. Try again.").font(Theme.Font.body).foregroundStyle(Theme.Color.text2)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, Theme.Metric.margin).padding(.vertical, 16)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .accessibilityIdentifier("proof.screen")
    }

    private func status(_ p: AIAttestation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mark = p.mark { PrivacyMarkView(mark: mark, size: 17) }
            Text(p.mark == .verified
                 ? "Your rewrites and answers run inside a sealed chip (a TEE) on NEAR AI. We check its hardware proof before we use it."
                 : p.mark == .privateOnly
                 ? "Your rewrites and answers run inside a sealed chip (a TEE) on NEAR AI. Its proof did not pass our check right now."
                 : "Private AI is off on this server. Rewrites and answers use a regular AI service.")
                .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).ringCard()
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.Color.text1)
            content()
        }
    }

    private func line(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(text).font(.system(size: 15)).foregroundStyle(Theme.Color.text1).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: keyboard: approval card (C-1) and sent card (C-2)

/// The bar over the keyboard card: "Send 5 USDC to ana.testnet ✕", or "Payment sent · View tx".
struct PayPanelBar: View {
    let panel: PayPanel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Buddy(size: 24)
            let i = panel.intent
            Text(panel.phase == .sent ? "Payment sent" : "Send \(i.amount) \(i.token) to \(i.recipient)")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            if panel.phase == .sent, let s = i.explorer_url, let url = URL(string: s) {
                Link(destination: url) {
                    HStack(spacing: 4) { Text("View tx"); Image(systemName: "arrow.up.right.square") }
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.Color.skyDeep)
                }
                .accessibilityIdentifier("paycard.tx")
            } else {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("paycard.close")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
    }
}

struct PayKeyboardCard: View {
    let panel: PayPanel
    let approve: () -> Void
    let reject: () -> Void
    let insert: () -> Void

    var body: some View {
        let i = panel.intent
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(i.amount).font(.system(size: 40, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                        Text(i.token).font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Color.text1)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("paycard.amount")
                    Spacer()
                    if panel.phase == .sent {
                        Label("Sent", systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Color.successInk)
                            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.Color.successChip, in: Capsule())
                            .accessibilityIdentifier("paycard.sent")
                    } else {
                        networkBadge(i.network)
                    }
                }
                if panel.phase == .sent {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sent you \(i.amount) \(i.token) \u{2713}").font(.system(size: 15)).foregroundStyle(Theme.Color.text1)
                        if let s = i.explorer_url {
                            Text(PayApprovalCard.shortTx(s)).font(.system(size: 15)).foregroundStyle(Theme.Color.skyDeep).lineLimit(1)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(String(i.recipient.prefix(2)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Theme.Color.text3.opacity(0.7), in: Circle())
                        Text(i.recipient).font(.system(size: 17)).foregroundStyle(Theme.Color.text1).lineLimit(1).minimumScaleFactor(0.7)
                            .accessibilityIdentifier("paycard.recipient")
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Network fee").font(.system(size: 12)).foregroundStyle(Theme.Color.text3)
                            Text("< 0.001 NEAR").font(.system(size: 15)).foregroundStyle(Theme.Color.text1)
                        }
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))

            if panel.phase == .sent {
                Button("Insert in chat", action: insert).buttonStyle(SkyPill(height: 50, font: .system(size: 18, weight: .semibold)))
                    .accessibilityIdentifier("paycard.insert")
                if let left = panel.leftAfter { hint("\(left) \(i.token) left for keyboard sends today.") }
            } else if case .failed(let line) = panel.phase {
                hint(line)
            } else {
                HStack(spacing: 10) {
                    Button("Reject", action: reject).buttonStyle(FrostPill(height: 50, font: .system(size: 17, weight: .semibold)))
                        .frame(width: 120)
                        .accessibilityIdentifier("paycard.reject")
                    Button(action: approve) {
                        HStack(spacing: 8) {
                            if panel.phase == .approving { ProgressView().tint(.white) } else { Image(systemName: "faceid") }
                            Text("Approve with Face ID")
                        }
                    }
                    .buttonStyle(SkyPill(height: 50, font: .system(size: 17, weight: .semibold)))
                    .disabled(panel.phase != .ready)
                    .accessibilityIdentifier("paycard.approve")
                }
                if let note = panel.note {
                    Text(note).font(.system(size: 14)).foregroundStyle(Theme.Color.warning).lineLimit(2).accessibilityIdentifier("paycard.note")
                } else if let k = i.keyboard {
                    hint("You paid this account \(k.paid_before == 1 ? "once" : "\(k.paid_before) times") before." + (k.left.map { " \($0) \(i.token) left today." } ?? ""))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.top, 2)
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Buddy(size: 18)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.Color.text2).lineLimit(2)
        }
    }
}

private func networkBadge(_ network: String) -> some View {
    HStack(spacing: 6) {
        Text("N").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white).frame(width: 20, height: 20).background(.black, in: Circle())
        Text("NEAR \(network)").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.Color.text1)
    }
    .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
    .background(Theme.Color.panel, in: Capsule())
    .accessibilityIdentifier("paycard.network")
}

// MARK: app: keyboard pay setup (C-3)

struct KeyboardPaySetupView: View {
    @Binding var limit: Int
    @Binding var faceID: Bool
    let account: String?
    let busy: Bool
    let done: Bool
    let error: String?
    let turnOn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 30).padding(.top, 8)
            Text("Pay from the keyboard").font(Theme.Font.title).foregroundStyle(Theme.Color.text1).padding(.top, 20)
            Text("Set this up once. Small sends then stay in the chat, with Face ID each time.")
                .font(Theme.Font.body).foregroundStyle(Theme.Color.text2).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard limit per day").font(.system(size: 15)).foregroundStyle(Theme.Color.text2)
                HStack(alignment: .center) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(limit)").font(.system(size: 52, weight: .bold)).monospacedDigit()
                        Text("USDC").font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Color.text1)
                    .accessibilityIdentifier("kbpay.limit")
                    Spacer()
                    stepper("minus", id: "kbpay.less") { limit = max(1, limit - 5) }
                    stepper("plus", id: "kbpay.more") { limit = min(25, limit + 5) }
                }
                Text("Over this, \(AppConfig.displayName) opens the full approval screen.").font(.system(size: 14)).foregroundStyle(Theme.Color.text3)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).ringCard().padding(.top, 24)
            HStack(spacing: 14) {
                Image(systemName: "faceid").font(.system(size: 22)).foregroundStyle(Theme.Color.skyDeep)
                    .frame(width: 42, height: 42).background(Theme.Color.iceSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Face ID for every send").font(.system(size: 17)).foregroundStyle(Theme.Color.text1)
                    Text("Asks before each keyboard send").font(.system(size: 14)).foregroundStyle(Theme.Color.text3)
                }
                Spacer()
                Toggle("", isOn: $faceID).labelsHidden().tint(Theme.Color.success).accessibilityIdentifier("kbpay.faceid")
            }
            .padding(.top, 24)
            HStack(spacing: 14) {
                Text("N").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white).frame(width: 24, height: 24).background(.black, in: Circle())
                    .frame(width: 42, height: 42).background(Theme.Color.iceSoft, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account ?? "Your Pip wallet").font(.system(size: 17)).foregroundStyle(Theme.Color.text1).lineLimit(1).truncationMode(.middle)
                    Text("\(PayNetwork.label) account").font(.system(size: 14)).foregroundStyle(Theme.Color.text3)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 24)
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.Color.warning).frame(maxWidth: .infinity) }
            HStack(spacing: 6) {
                Buddy(size: 18)
                Text("New recipients always open \(AppConfig.displayName) first.").font(.system(size: 15)).foregroundStyle(Theme.Color.text2)
            }
            .frame(maxWidth: .infinity).padding(.bottom, 14)
            Button(action: turnOn) {
                if busy { ProgressView().tint(.white) } else { Text(done ? "Keyboard pay is on \u{2713}" : "Turn on keyboard pay") }
            }
            .buttonStyle(SkyPill())
            .disabled(busy)
            .accessibilityIdentifier("kbpay.turnOn")
        }
        .padding(.horizontal, Theme.Metric.margin).padding(.bottom, 12)
        .background(Theme.Color.bg.ignoresSafeArea())
    }

    private func stepper(_ icon: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                .frame(width: 56, height: 56).background(Theme.Color.panel, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
