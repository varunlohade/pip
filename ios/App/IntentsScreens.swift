import CoreImage.CIFilterBuiltins
import SwiftUI

// Pip Pay screens for NEAR Intents beyond paying: the owner's own addresses on other chains (where swaps land) and
// "Top up from another chain" (a checked 1Click deposit address, with a QR, that delivers to the Pip wallet).

extension WalletSection {
    /// A Pip Pay row under the wallet, in the same style as the Pip Pay link.
    func intentsLink<D: View>(_ title: String, icon: String, id: String, @ViewBuilder to dest: @escaping () -> D) -> some View {
        NavigationLink { dest() } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(Theme.Color.skyDeep)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Color.text1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.text3)
            }
            .padding(.horizontal, 16).frame(height: 48).ringCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// My addresses: one address per chain, checked by the server's validator for that chain. Only the app can change them.
@MainActor
final class OwnAddressesModel: ObservableObject {
    @Published var saved: [OwnAddresses.Saved] = []
    @Published var chains: [OwnAddresses.Chain] = []
    @Published var error: String?
    @Published var busy = false

    func load() async {
        do {
            let r = try await APIClient.shared().ownAddresses()
            saved = r.addresses
            chains = r.chains
            error = nil
        } catch {
            self.error = plainLine(error)
        }
    }

    /// True when saved. The server's reason shows when the address does not fit the chain.
    func save(chain: String, address: String) async -> Bool {
        guard let key = ApproverKeychain().get() else { error = "Set up Pip Pay first."; return false }
        busy = true
        defer { busy = false }
        do {
            try await APIClient.shared().setOwnAddress(chain: chain, address: address.trimmingCharacters(in: .whitespacesAndNewlines), approverKey: key)
            await load()
            return true
        } catch {
            self.error = plainLine(error)
            return false
        }
    }

    func remove(_ chain: String) async {
        guard let key = ApproverKeychain().get() else { return }
        do {
            try await APIClient.shared().deleteOwnAddress(chain: chain, approverKey: key)
            await load()
        } catch {
            self.error = plainLine(error)
        }
    }
}

struct OwnAddressesView: View {
    @StateObject private var model = OwnAddressesModel()
    @State private var chain = "base"
    @State private var address = ""

    var body: some View {
        List {
            Section {
                ForEach(model.saved, id: \.chain) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.chain_name).font(.system(size: 15, weight: .semibold))
                        Text(a.address).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Color.text2).textSelection(.enabled)
                    }
                    .swipeActions { Button("Remove", role: .destructive) { Task { await model.remove(a.chain) } } }
                    .accessibilityIdentifier("addresses.row.\(a.chain)")
                }
                if model.saved.isEmpty {
                    Text("No addresses yet. A swap to another chain goes only to an address you save here.")
                        .font(.system(size: 14)).foregroundStyle(Theme.Color.text2)
                }
            } header: { Text("My addresses") }
            Section {
                Picker("Chain", selection: $chain) {
                    ForEach(model.chains, id: \.id) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("addresses.chain")
                TextField("Your address on this chain", text: $address)
                    .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("addresses.field")
                Button("Save address") {
                    Task { if await model.save(chain: chain, address: address) { address = "" } }
                }
                .disabled(address.isEmpty || model.busy)
                .accessibilityIdentifier("addresses.save")
                if let e = model.error {
                    Text(e).font(.system(size: 13)).foregroundStyle(Theme.Color.warning).accessibilityIdentifier("addresses.error")
                }
            } header: { Text("Add or replace") } footer: {
                Text("Pip checks the format for each chain. Use an address you own: swaps send money there.")
            }
        }
        .navigationTitle("My addresses")
        .task { await model.load() }
    }
}

/// Top up from another chain: the payer chain and amount, then a checked deposit address and its QR. Pip moves no money;
/// the owner pays it from MetaMask, Phantom or any wallet, and the money lands in Pip as USDC or USDT on NEAR.
@MainActor
final class TopUpModel: ObservableObject {
    @Published var card: RequestCard?
    @Published var status: RequestStatus?
    @Published var error: String?
    @Published var busy = false
    private var poll: Task<Void, Never>?

    func quote(amount: String, token: String, chain: String) async {
        busy = true
        defer { busy = false }
        poll?.cancel()
        status = nil
        do {
            let p = XchainParsed(valid: true, kind: "topup", amount: amount, token: token, chain: chain)
            let c = try await APIClient.shared().requestPay(p)
            card = c
            error = nil
            if c.live, let id = c.request?.id { watch(id) }
        } catch {
            card = nil
            self.error = plainLine(error)
        }
    }

    private func watch(_ id: String) {
        poll = Task { [weak self] in
            for _ in 0..<400 {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                guard let s = try? await APIClient.shared().requestStatus(id) else { continue }
                guard let self, !Task.isCancelled else { return }
                self.status = s
                if s.done { return }
            }
        }
    }

    deinit { poll?.cancel() }
}

struct TopUpView: View {
    @StateObject private var model = TopUpModel()
    @State private var chain = "base"
    @State private var token = "USDC"
    @State private var amount = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Pay from MetaMask, Phantom or any wallet on another chain. NEAR Intents delivers it to your Pip wallet.")
                    .font(.system(size: 15)).foregroundStyle(Theme.Color.text2)
                Picker("Pay from", selection: $chain) {
                    ForEach(ChainChoice.payer, id: \.words) { Text($0.title).tag($0.words) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("topup.chain")
                Picker("Token", selection: $token) { Text("USDC").tag("USDC"); Text("USDT").tag("USDT") }
                    .pickerStyle(.segmented)
                TextField("Amount, like 20", text: $amount).keyboardType(.decimalPad)
                    .padding(12).ringCard().accessibilityIdentifier("topup.amount")
                Button(model.busy ? "Getting an address\u{2026}" : "Get deposit address") {
                    Task { await model.quote(amount: amount, token: token, chain: chain) }
                }
                .buttonStyle(SkyPill(height: 50, font: .system(size: 17, weight: .semibold)))
                .disabled(amount.isEmpty || model.busy)
                .accessibilityIdentifier("topup.get")
                if let e = model.error { Text(e).font(.system(size: 14)).foregroundStyle(Theme.Color.warning) }
                if let c = model.card { result(c) }
            }
            .padding(Theme.Space.m)
        }
        .navigationTitle("Top up")
    }

    @ViewBuilder private func result(_ c: RequestCard) -> some View {
        let t = RequestText(c)
        VStack(alignment: .leading, spacing: 8) {
            if c.preview {
                Label(XchainCardText.previewTitle, systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Color.skyDeep)
                    .accessibilityIdentifier("topup.preview")
            }
            Text(t.gets).font(.system(size: 18, weight: .bold)).accessibilityIdentifier("topup.gets")
            Text(t.pays).font(.system(size: 15))
            if let a = c.deposit_address, c.live {
                if let img = Self.qr(a) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 200, height: 200)
                        .frame(maxWidth: .infinity).accessibilityIdentifier("topup.qr")
                }
                Text(a).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("topup.address")
                Button("Copy address") { UIPasteboard.general.string = a }.buttonStyle(FrostPill(height: 44, font: .system(size: 16, weight: .semibold)))
                if let d = c.validUntil { Text("Send it before \(RequestText.time(d, timeZone: .current)).").font(.system(size: 14)) }
            }
            if let s = model.status {
                Text(RequestText.status(s)).font(.system(size: 15, weight: .semibold)).accessibilityIdentifier("topup.status")
            }
            if let why = t.blocked { Text(why).font(.system(size: 14)).foregroundStyle(Theme.Color.warning).accessibilityIdentifier("topup.blocked") }
            Text(t.slippage).font(.system(size: 13)).foregroundStyle(Theme.Color.text2)
            Text("Routed by NEAR Intents solvers" + (t.path.isEmpty ? "" : ": " + t.path)).font(.system(size: 13)).foregroundStyle(Theme.Color.text2)
            Text(t.refund).font(.system(size: 13)).foregroundStyle(Theme.Color.text2)
        }
        .padding(14).ringCard()
    }

    static func qr(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
