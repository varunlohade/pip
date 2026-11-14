import Foundation
import Security
import SwiftUI

/// The pay calls the app makes. APIClient is the real one; tests pass a fake.
protocol PayAPI {
    func payIntent(_ id: String) async throws -> PayIntent
    func approvePay(_ i: PayIntent, approverKey: String) async throws -> PayIntent
    func rejectPay(_ id: String) async throws -> PayIntent
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
}

/// One payment on the approval card: load it, approve it behind Face ID, or reject it.
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
    private let auth: Authenticator
    private let keys: ApproverKeys
    private let recordSent: (PaySent) -> Void
    private let now: () -> Date

    init(id: String, api: PayAPI, auth: Authenticator, keys: ApproverKeys, recordSent: @escaping (PaySent) -> Void, now: @escaping () -> Date = Date.init) {
        self.id = id
        self.api = api
        self.auth = auth
        self.keys = keys
        self.recordSent = recordSent
        self.now = now
    }

    static func live(id: String) -> ApprovalModel {
        ApprovalModel(id: id, api: APIClient.shared(), auth: DeviceOwnerAuth(), keys: ApproverKeychain(),
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
        phase = .approving
        note = nil
        guard await auth.confirm("Send \(i.amount) \(i.token) to \(i.recipient)") == .approved else {
            phase = .ready
            note = "Not approved. Nothing was sent."
            return
        }
        do {
            let done = try await api.approvePay(i, approverKey: try await approverKey())
            intent = done
            show(done)
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

    private func approverKey() async throws -> String {
        if let k = keys.get() { return k }
        let k = try await api.registerApprover(current: nil)
        guard keys.set(k) else { throw APIError.message("Could not keep the approval key on this phone.") }
        return k
    }

    private func show(_ i: PayIntent) {
        switch i.status {
        case "pending": phase = .ready
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
            NavigationLink { KeyboardPaySetup(account: wallet?.account_id) } label: {
                HStack {
                    Image(systemName: "keyboard").foregroundStyle(Theme.Color.skyDeep)
                    Text("Pay from the keyboard").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    Text(SharedStore.payKeyboardLimit.map { "\($0) USDC a day" } ?? "Set up").font(.system(size: 14)).foregroundStyle(Theme.Color.text3)
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

/// Keyboard pay setup (C-3): the approver key signs for a capped keyboard key, which goes to the shared Keychain.
@MainActor
final class KeyboardPayModel: ObservableObject {
    @Published var limit = Int(SharedStore.payKeyboardLimit.flatMap(Double.init) ?? 20)
    @Published var faceID = SharedStore.payFaceID
    @Published var busy = false
    @Published var done = SharedStore.payKeyboardLimit != nil && Keychain.get(.payKeyboardKey) != nil
    @Published var error: String?

    private let api: PayAPI & KeyboardPayAPI
    private let keys: ApproverKeys
    /// Where the keyboard key and settings go: the shared Keychain and the App Group.
    private let save: (_ key: String, _ limit: String, _ faceID: Bool) -> Bool

    init(api: PayAPI & KeyboardPayAPI, keys: ApproverKeys, save: @escaping (String, String, Bool) -> Bool) {
        self.api = api
        self.keys = keys
        self.save = save
    }

    static func live() -> KeyboardPayModel {
        KeyboardPayModel(api: APIClient.shared(), keys: ApproverKeychain()) { key, limit, faceID in
            SharedStore.payFaceID = faceID
            SharedStore.payKeyboardLimit = limit
            return Keychain.set(.payKeyboardKey, key) == errSecSuccess
        }
    }

    func turnOn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let approver: String
            if let k = keys.get() {
                approver = k
            } else {
                approver = try await api.registerApprover(current: nil)
                guard keys.set(approver) else { throw APIError.message("Could not keep the approval key on this phone.") }
            }
            let out = try await api.setKeyboardPay(usdcDaily: "\(limit)", nearDaily: "\(limit)", approverKey: approver)
            guard save(out.key, out.usdc, faceID) else { throw APIError.message("Could not save keyboard pay on this phone.") }
            limit = Int(Double(out.usdc) ?? Double(limit))
            done = true
        } catch {
            self.error = plainLine(error)
        }
    }
}

protocol KeyboardPayAPI {
    func setKeyboardPay(usdcDaily: String, nearDaily: String, approverKey: String) async throws -> (key: String, usdc: String, near: String)
}

extension APIClient: KeyboardPayAPI {}

struct KeyboardPaySetup: View {
    let account: String?
    @StateObject private var model = KeyboardPayModel.live()

    var body: some View {
        KeyboardPaySetupView(limit: $model.limit, faceID: $model.faceID, account: account, busy: model.busy, done: model.done,
                             error: model.error, turnOn: { Task { await model.turnOn() } })
            .onChange(of: model.faceID) { _, on in SharedStore.payFaceID = on }
            .onChange(of: model.limit) { _, _ in model.done = false }
    }
}
