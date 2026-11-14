import Foundation
import Security
import SwiftUI

/// The pay calls the app makes. APIClient is the real one; tests pass a fake.
protocol PayAPI {
    func payIntent(_ id: String) async throws -> PayIntent
    func unsignedPay(_ i: PayIntent, approverKey: String?) async throws -> PayUnsigned
    func submitPay(_ id: String, signature: Data) async throws -> PayIntent
    func rejectPay(_ id: String) async throws -> PayIntent
    func payNetwork() async throws -> PayNetworkInfo
    func setPayNetwork(_ network: String, approverKey: String) async throws -> PayNetworkInfo
    func registerPayKey(_ publicKeyHex: String, approverKey: String) async throws -> PayRegistered
    func registerApprover(current: String?) async throws -> String
    func payWallet() async throws -> PayWallet
    func aiAttestation() async throws -> AIAttestation
}

extension APIClient: PayAPI {}

protocol ApproverKeys {
    func get() -> String?
    @discardableResult func set(_ key: String?) -> Bool
}

/// The approver key, in the app's own Keychain group (its application identifier). The keyboard's entitlements list only
/// the shared group, so the keyboard cannot read it and cannot approve a payment.
struct ApproverKeychain: ApproverKeys {
    static let service = "com.orseliyas.pip.approver"
    static let account = "approver_key"
    static var group: String {
        (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "") + "com.orseliyas.pip"
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account, kSecAttrAccessGroup as String: Self.group]
    }

    func get() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    func set(_ key: String?) -> Bool {
        SecItemDelete(query() as CFDictionary)
        guard let key else { return true }
        var q = query()
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess && get() == key
    }
}

enum PayApprover {
    /// First launch after sign-in: make the approver key once. A server that already has one for a live session says 409;
    /// the key then stays as it is.
    static func ensure(api: PayAPI, keys: ApproverKeys) async {
        guard keys.get() == nil, let k = try? await api.registerApprover(current: nil) else { return }
        keys.set(k)
    }

    /// The approver key, made now if this phone has none.
    static func key(api: PayAPI, keys: ApproverKeys) async throws -> String {
        if let k = keys.get() { return k }
        let k = try await api.registerApprover(current: nil)
        guard keys.set(k) else { throw APIError.message("Could not keep the approval key on this phone.") }
        return k
    }
}

/// One payment on the approval card: load it, check the server's transaction, sign it with Face ID, or reject it.
@MainActor
final class ApprovalModel: ObservableObject {
    typealias Phase = PayPhase

    let id: String
    @Published var intent: PayIntent?
    @Published var wallet: PayWallet?
    @Published var mark: PrivacyMark?
    @Published var phase: Phase = .loading
    /// One quiet line under the buttons, such as "Not approved. Nothing was sent."
    @Published var note: String?

    private let api: PayAPI
    private let signer: PaySigner
    private let keys: ApproverKeys
    private let recordSent: (PaySent) -> Void
    private let now: () -> Date

    init(id: String, api: PayAPI, signer: PaySigner, keys: ApproverKeys, recordSent: @escaping (PaySent) -> Void, now: @escaping () -> Date = Date.init) {
        self.id = id
        self.api = api
        self.signer = signer
        self.keys = keys
        self.recordSent = recordSent
        self.now = now
    }

    static func live(id: String) -> ApprovalModel {
        ApprovalModel(id: id, api: APIClient.shared(), signer: PayKeyVault(), keys: ApproverKeychain(),
                      recordSent: { SharedStore.paySent = $0; SharedStore.payPending = nil })
    }

    func load() async {
        do {
            let i = try await api.payIntent(id)
            intent = i
            show(i)
        } catch {
            phase = .failed(plainLine(error))
            return
        }
        async let w = try? api.payWallet()
        async let a = try? api.aiAttestation()
        wallet = await w
        mark = await a?.mark
    }

    func approve() async {
        guard let i = intent, phase == .ready else { return }
        guard let account = signer.accountID() else {
            note = "Set up Pip Pay on Home first. Nothing was sent."
            return
        }
        phase = .approving
        note = nil
        do {
            let u = try await api.unsignedPay(i, approverKey: try await PayApprover.key(api: api, keys: keys))
            guard case .success(let ok) = PayTxCheck.check(u, intent: i, account: account) else {
                phase = .failed(PayTxCheck.refusedLine)
                _ = try? await api.rejectPay(i.id)
                return
            }
            switch await signer.sign(ok.hash, prompt: "Send \(i.amount) \(i.token) to \(i.recipient)") {
            case .signed(let sig):
                let done = try await api.submitPay(i.id, signature: sig)
                intent = done
                show(done)
            case .denied:
                phase = .ready
                note = "Not approved. Nothing was sent."
            case .unavailable:
                phase = .ready
                note = "Face ID is off for Pip, so it cannot sign. Nothing was sent."
            }
        } catch {
            phase = .ready
            note = plainLine(error)
        }
    }

    func reject() async {
        guard let i = intent, phase == .ready else { return }
        do {
            intent = try await api.rejectPay(i.id)
            phase = .rejected
        } catch {
            note = plainLine(error)
        }
    }

    private func show(_ i: PayIntent) {
        switch i.status {
        case "pending", "built": phase = .ready
        case "sent":
            phase = .sent
            recordSent(PaySent(i, at: now()))
        case "rejected": phase = .rejected
        case "expired": phase = .failed("This payment expired. Type it again in the keyboard.")
        case "failed": phase = .failed("It did not go through. Nothing left your wallet.")
        default: phase = .failed("Not confirmed yet. Check the link on NearBlocks.")
        }
    }
}

/// The approval sheet: the card, then the sent state.
struct ApprovalSheet: View {
    @StateObject var model: ApprovalModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PayApprovalCard(intent: model.intent, wallet: model.wallet, mark: model.mark, phase: model.phase, note: model.note,
                        approve: { Task { await model.approve() } },
                        reject: { Task { await model.reject() } },
                        close: { dismiss() })
            .task { await model.load() }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
    }
}

/// Home's wallet row and the Private AI proof link.
struct WalletSection: View {
    @State private var wallet: PayWallet?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            WalletCard(wallet: wallet, failed: failed)
            NavigationLink { PaySetup() } label: {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(Theme.Color.skyDeep)
                    Text("Pip Pay").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    Text(wallet.map { PaySetupView.short($0.account_id) } ?? "Set up").font(.system(size: 14)).foregroundStyle(Theme.Color.text3)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Color.text3)
                }
                .padding(.horizontal, 16).frame(height: 48).ringCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.keyboardPay")
            NavigationLink { AttestationScreen() } label: { PrivateAIRow() }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.privateAI")
        }
        .padding(.horizontal, Theme.Metric.cardInset + 8)
        .task {
            await PayApprover.ensure(api: APIClient.shared(), keys: ApproverKeychain())
            do { wallet = try await APIClient.shared().payWallet() } catch { failed = true }
        }
    }
}

struct AttestationScreen: View {
    @State private var proof: AIAttestation?
    @State private var failed = false

    var body: some View {
        AIProofView(proof: proof, failed: failed)
            .task {
                do { proof = try await APIClient.shared().aiAttestation() } catch { failed = true }
            }
    }
}

/// Pip Pay setup (C-3): make the phone's key, register its implicit account, show the balance, switch networks.
@MainActor
final class PaySetupModel: ObservableObject {
    /// The account registered on the current network, when it is this phone's key.
    @Published var account: String?
    @Published var wallet: PayWallet?
    @Published var network = PayNetwork.name
    @Published var mainnetEnabled = false
    @Published var busy = false
    @Published var error: String?
    /// The network the server last confirmed.
    private var confirmed = PayNetwork.name

    private let api: PayAPI
    private let vault: PayKeyVault
    private let keys: ApproverKeys
    private let saveNetwork: (String) -> Void

    init(api: PayAPI, vault: PayKeyVault, keys: ApproverKeys, saveNetwork: @escaping (String) -> Void) {
        self.api = api
        self.vault = vault
        self.keys = keys
        self.saveNetwork = saveNetwork
    }

    static func live() -> PaySetupModel {
        PaySetupModel(api: APIClient.shared(), vault: PayKeyVault(), keys: ApproverKeychain()) { SharedStore.payNetwork = $0 }
    }

    /// The key outlives a logout, so after the next sign-in its same public key is registered for the new session.
    func load() async {
        do {
            show(try await api.payNetwork())
            if account == nil, let pk = vault.accountID() { await register(pk) } else { await refreshWallet() }
        } catch {
            self.error = plainLine(error)
        }
    }

    func setUp() async {
        busy = true
        error = nil
        defer { busy = false }
        guard let pk = vault.ensure() else {
            error = "Turn on a passcode and Face ID to keep a key on this phone."
            return
        }
        await register(pk)
    }

    var hasKey: Bool { vault.accountID() != nil }

    /// "Remove wallet from this phone", after the owner confirmed the balance warning. The key is gone for good.
    func removeWallet() {
        vault.forget()
        account = nil
        wallet = nil
    }

    /// Mainnet only when the server has it on. The key stays the same; its account is registered on the new network.
    func switchTo(_ n: String) async {
        guard n != confirmed else { return }
        guard n == "testnet" || mainnetEnabled else { network = confirmed; return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let info = try await api.setPayNetwork(n, approverKey: try await PayApprover.key(api: api, keys: keys))
            show(info)
            wallet = nil
            if let pk = vault.accountID() { await register(pk) }
        } catch {
            network = confirmed
            self.error = plainLine(error)
        }
    }

    private func register(_ pk: String) async {
        do {
            let r = try await api.registerPayKey(pk, approverKey: try await PayApprover.key(api: api, keys: keys))
            account = r.account_id == pk ? pk : nil
            await refreshWallet()
        } catch {
            self.error = plainLine(error)
        }
    }

    private func show(_ info: PayNetworkInfo) {
        network = info.network
        confirmed = info.network
        saveNetwork(info.network)
        if let m = info.mainnet_enabled { mainnetEnabled = m }
        account = info.account_id != nil && info.account_id == vault.accountID() ? info.account_id : nil
    }

    private func refreshWallet() async {
        guard account != nil else { return }
        wallet = try? await api.payWallet()
    }
}

struct PaySetup: View {
    @StateObject private var model = PaySetupModel.live()

    var body: some View {
        PaySetupView(account: model.account, wallet: model.wallet,
                     network: Binding(get: { model.network }, set: { n in model.network = n; Task { await model.switchTo(n) } }),
                     mainnetEnabled: model.mainnetEnabled, busy: model.busy, error: model.error, hasKey: model.hasKey,
                     setUp: { Task { await model.setUp() } }, remove: { model.removeWallet() })
            .task { await model.load() }
    }
}
