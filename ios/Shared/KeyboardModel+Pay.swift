import Foundation

/// The keyboard's approval card: one payment, where it is, and what the owner still has to do.
struct PayPanel: Equatable {
    var intent: PayIntent
    var phase: PayPhase = .ready
    /// One quiet line, such as "Not approved. Nothing was sent."
    var note: String?
    /// Cross-chain: the checked quote the card shows.
    var xchain: XchainCard?
    /// First time paying this address: the owner taps how it ends before the PIN.
    var confirm: AddressConfirm?
    /// A re-quote's transaction, built and waiting for the PIN again on the new card.
    var pending: PayUnsigned?
    /// Cross-chain, after the deposit landed.
    var swap: SwapState?
    /// Pip's own PIN pad, with the digits typed so far.
    var pin: String?
    /// The keyboard can read a PIN-sealed key: "Approve with PIN". Else "Set a payment PIN in Pip".
    var pinReady = false
    /// The PIN is being checked (PBKDF2 takes a moment).
    var checkingPIN = false
    /// "Approve in Pip": too many wrong tries.
    var offerApp = false

    init(intent: PayIntent, xchain: XchainCard? = nil) {
        self.intent = intent
        self.xchain = xchain
        if let card = xchain {
            if card.firstTime, let to = card.destination?.recipient { confirm = AddressConfirm(to) }
        } else if intent.new_recipient != false {
            confirm = AddressConfirm(intent.recipient)
        }
    }

    var requoted: Bool { pending != nil }
    /// Approve is on: a ready card, a verified quote, and the address confirmed when it is new.
    var canApprove: Bool {
        phase == .ready && (xchain?.approvable ?? true) && (confirm?.confirmed ?? true)
    }
    /// What the system Face ID sheet says.
    var prompt: String {
        if let n = xchain?.numbers, let d = xchain?.destination {
            return "Send \(n.amount_out.text) \(n.amount_out.symbol) on \(d.chain_name) to \(XchainCardText.short(d.recipient))"
        }
        return "Send \(intent.amount) \(intent.token) to \(intent.recipient)"
    }
}

/// Type-to-pay in the keyboard (design C). Every payment, same-chain or cross-chain, to a known or a new recipient, is approved
/// here with Pip's payment PIN. The PIN opens the phone key once: it signs a proof over the intent (the server needs it for a new
/// recipient), then the transaction, after the phone has checked it against the card. The server keeps the caps.
extension KeyboardModel {
    /// How often a sent cross-chain payment is checked. Tests make it short.
    static var swapPollEvery: Duration = .seconds(3)

    /// Reads a payment from the text. True when one shows, so the sentence does not also go to /v1/suggest.
    func updatePay(_ text: String, quiet: Bool) -> Bool {
        let found = PayDetect.detect(text)
        // Text with no payment ends the "already proposed" memory, so the same payment typed again offers the chip again.
        if found == nil, !payDone.isEmpty { payDone = [] }
        guard !quiet, payPanel == nil, let d = found, !payDone.contains(d) else {
            if payOffer != nil { payOffer = nil }
            if !quiet, payPanel == nil, found == nil, let t = PayDetect.mainnetSuffix(text) {
                let offer = XchainOffer.refused(PayDetect.suffixHelp, trigger: t)
                if xchainOffer != offer { xchainOffer = offer }
                return true
            }
            return updateXchain(text, quiet: quiet || found != nil)
        }
        if payOffer != d { payOffer = d }
        if xchainOffer != nil { xchainOffer = nil }
        return true
    }

    /// Cross-chain: a cheap regex decides when to ask; the server's parse decides what the payment is.
    private func updateXchain(_ text: String, quiet: Bool) -> Bool {
        let words = quiet || lineHasSecret || payPanel != nil ? nil : XchainDetect.candidate(text)
        if words == nil, !xchainDone.isEmpty { xchainDone = [] }
        guard let words, !xchainDone.contains(words) else {
            xchainTask?.cancel()
            xchainAsked = nil
            if xchainOffer != nil { xchainOffer = nil }
            return false
        }
        if PayNetwork.name != "mainnet" {
            let offer = XchainOffer.needsMainnet(trigger: words)
            if xchainOffer != offer { xchainOffer = offer }
            return true
        }
        guard words != xchainAsked else { return true }
        xchainAsked = words
        xchainTask?.cancel()
        let api = deps.api()
        xchainTask = Task { [weak self] in
            // Typing on: ask once the words settle.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let parsed = try? await api.parseXchain(words)
            guard let self, !Task.isCancelled, self.xchainAsked == words else { return }
            self.xchainOffer = Self.offer(parsed, words: words)
        }
        return true
    }

    /// The bar's reading of the server's parse: a payment to review, "Which chain?" for an 0x address, or the reason it cannot run.
    static func offer(_ parsed: XchainParsed?, words: String) -> XchainOffer? {
        switch parsed {
        case .some(let p) where p.valid && p.kind == "xchain": .ready(p, trigger: words)
        case .some(let p) where !p.valid && p.needs == "chain" && Flags.dollarPay: .whichChain(trigger: words)
        case .some(let p) where !p.valid: .refused(p.reason ?? "Pip cannot send this yet", trigger: words)
        default: nil
        }
    }

    /// The router said "pay" or "xchain_pay" but the phone's regex read no payment: the server's parse reads the sentence.
    /// On testnet a cross-chain ask shows the "needs Mainnet" line, never nothing.
    func routeToPay(_ sentence: String, label: String) {
        guard payOffer == nil, xchainOffer == nil, payPanel == nil, !lineHasSecret else { return }
        if PayNetwork.name != "mainnet" {
            if label == "xchain_pay" { xchainOffer = .needsMainnet(trigger: sentence) }
            return
        }
        xchainAsked = sentence
        xchainTask?.cancel()
        let api = deps.api()
        xchainTask = Task { [weak self] in
            let parsed = try? await api.parseXchain(sentence)
            guard let self, !Task.isCancelled, self.xchainAsked == sentence else { return }
            self.xchainOffer = Self.offer(parsed, words: sentence)
        }
    }

    /// A "Which chain?" chip: " on base" goes after the typed words, and the payment is read again with the chain named.
    func pickChain(_ words: String) {
        host?.playClick()
        let before = host?.contextBeforeInput ?? ""
        host?.insert((before.last?.isWhitespace ?? true ? "" : " ") + "on \(words)")
        textChanged()
    }

    var payItem: BarItems.Item? {
        if let d = payOffer { return BarItems.Item(id: "pay", title: d.label, detail: "Approve", action: .pay, trigger: d.trigger) }
        switch xchainOffer {
        case .ready(let p, let t):
            let to = XchainCardText.short(p.recipient ?? "")
            return BarItems.Item(id: "pay", title: "Send \(p.amount ?? "") \(p.token ?? "") to \(to)", detail: "Review", action: .pay, trigger: t)
        case .needsMainnet(let t):
            return BarItems.Item(id: "pay", title: XchainOffer.mainnetLine, tone: .secondary, trigger: t)
        case .refused(let why, let t):
            return BarItems.Item(id: "pay", title: why, tone: .secondary, trigger: t)
        case .whichChain(let t):
            return BarItems.Item(id: "pay", title: "Which chain?", tone: .secondary, trigger: t)
        case nil:
            return nil
        }
    }

    var paidItem: BarItems.Item? {
        paySent.map { BarItems.Item(id: "paid", title: $0.label, detail: $0.line, tone: .success) }
    }

    /// Tap on the chip: the server keeps the exact fields (10 minutes; 2 for a cross-chain quote), and the card opens here.
    func tapPay() {
        if case .ready(let p, let words) = xchainOffer { return tapXchain(p, words: words) }
        guard let d = payOffer else { return }
        host?.playClick()
        payTask?.cancel()
        payDone.insert(d)
        payOffer = nil
        bar = .working("Getting it ready\u{2026}")
        let api = deps.api(), signer = deps.signer()
        payTask = Task { [weak self] in
            do {
                let intent = try await api.createPayIntent(d)
                guard let self, !Task.isCancelled else { return }
                self.deps.store.payPending = intent.id
                if signer.accountID() != nil { self.showPanel(PayPanel(intent: intent)) } else { self.openAppToSetUp(intent) }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.payDone.remove(d)
                self.bar = .error(plainLine(error))
            }
        }
    }

    private func tapXchain(_ p: XchainParsed, words: String) {
        host?.playClick()
        payTask?.cancel()
        xchainDone.insert(words)
        xchainOffer = nil
        bar = .working("Getting a price\u{2026}")
        let api = deps.api(), signer = deps.signer()
        payTask = Task { [weak self] in
            do {
                let q = try await api.quoteXchain(p)
                guard let self, !Task.isCancelled else { return }
                if let id = q.intent?.id { self.deps.store.payPending = id }
                guard signer.accountID() != nil else {
                    if let i = q.intent { self.openAppToSetUp(i) } else { self.bar = .error("Set up Pip Pay in \(AppConfig.displayName) first") }
                    return
                }
                // An unverified quote still shows its card, with the reason and Approve off.
                let intent = q.intent ?? PayIntent(id: "", amount: "", token: p.from ?? "", recipient: "", status: "refused", network: "mainnet",
                                                   tx_hash: nil, explorer_url: nil, deep_link: "", new_recipient: true)
                var card = q.card
                if card.destination == nil, let chain = p.chain, let to = p.recipient {
                    card.destination = .init(chain: chain, chain_name: chain.capitalized, recipient: to, first_time: true)
                }
                self.showPanel(PayPanel(intent: intent, xchain: card))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.xchainDone.remove(words)
                self.bar = .error(plainLine(error))
            }
        }
    }

    private func showPanel(_ p: PayPanel) {
        var p = p
        let pinVault = deps.pin()
        p.pinReady = pinVault.isSet
        beat(pinReady: p.pinReady, pinStatus: pinVault.sealedStatus)
        bar = .idle
        notesOpen = false
        writeOpen = false
        payPanel = p
    }

    /// No NEAR key on this phone yet: Pip Pay is set up in the app.
    func openAppToSetUp(_ intent: PayIntent) {
        payPanel = nil
        let opened = URL(string: intent.deep_link).map { host?.open($0) ?? false } ?? false
        bar = .done(opened ? "Opening \(AppConfig.displayName)\u{2026}" : "Set up Pip Pay in \(AppConfig.displayName) first")
    }

    /// First time paying this address: one of the three endings.
    func pickAddressEnd(_ end: String) {
        guard var p = payPanel, var c = p.confirm, p.phase == .ready else { return }
        host?.playClick()
        c.picked = end
        p.confirm = c
        p.note = c.confirmed ? nil : "That is not how this address ends. Check it and try again."
        payPanel = p
    }

    /// "Approve with PIN": the PIN pad opens straight away. The keyboard never tries Face ID (on a real phone it hangs or does
    /// nothing there). No PIN on this phone yet: "Set a payment PIN in Pip" opens the app's PIN setup.
    func approvePayInKeyboard() {
        guard var p = payPanel, p.canApprove, p.pin == nil else { return }
        host?.playClick()
        let pinVault = deps.pin()
        p.pinReady = pinVault.isSet
        p.offerApp = false
        if !p.pinReady {
            let opened = URL(string: PayFallback.pinSetupLink).map { host?.open($0) ?? false } ?? false
            p.note = opened ? nil : PayFallback.setPIN
        } else if pinVault.isLocked {
            p.note = PayFallback.locked
            p.offerApp = true
        } else {
            p.pin = ""
            p.note = nil
        }
        payPanel = p
    }

    /// One digit on the PIN pad. The sixth digit checks the PIN.
    func typePINDigit(_ d: String) {
        guard var p = payPanel, var pin = p.pin, !p.checkingPIN, pin.count < PayPIN.length, d.count == 1, d.allSatisfy(\.isNumber) else { return }
        host?.playClick()
        pin += d
        p.pin = pin
        payPanel = p
        if pin.count == PayPIN.length { checkPIN(pin) }
    }

    func deletePINDigit() {
        guard var p = payPanel, let pin = p.pin, !p.checkingPIN, !pin.isEmpty else { return }
        host?.playClick()
        p.pin = String(pin.dropLast())
        payPanel = p
    }

    private func checkPIN(_ pin: String) {
        guard var p = payPanel else { return }
        p.checkingPIN = true
        p.note = nil
        payPanel = p
        let pinVault = deps.pin()
        payTask = Task { [weak self] in
            let result = await pinVault.unlock(pin)
            guard let self, !Task.isCancelled, var now = self.payPanel else { return }
            now.checkingPIN = false
            switch result {
            case .ready(let key):
                defer { key.wipe() }
                now.pin = nil
                now.phase = .approving
                self.payPanel = now
                await self.send(now, sign: key.sign)
                return
            case .wrong(let left):
                now.pin = ""
                now.note = "Wrong PIN. \(left) \(left == 1 ? "try" : "tries") left."
            case .locked:
                now.pin = nil
                now.note = PayFallback.locked
                now.offerApp = true
            case .notSet:
                now.pin = nil
                now.note = PayFallback.useApp
                now.offerApp = true
            }
            self.payPanel = now
        }
    }

    /// "Approve in Pip": the app reads the same payment by id, asks for Face ID there and signs it.
    func approvePayInApp() {
        guard let p = payPanel, !p.intent.id.isEmpty else { return }
        host?.playClick()
        payTask?.cancel()
        payPanel = nil
        let opened = URL(string: p.intent.deep_link).map { host?.open($0) ?? false } ?? false
        bar = .done(opened ? "Opening \(AppConfig.displayName)\u{2026}" : "Open \(AppConfig.displayName) to approve this payment")
    }

    /// The proof for the server, then the checked transaction, signed with `sign` (the PIN's key).
    private func send(_ p: PayPanel, sign: @escaping (Data) -> Data?) async {
        let api = deps.api(), signer = deps.signer()
        guard let account = signer.accountID() else {
            payPanel?.phase = .ready
            payPanel?.note = PayFallback.useApp
            payPanel?.offerApp = true
            return
        }
        do {
            var i = p.intent
            let u: PayUnsigned
            if let built = p.pending {
                u = built
            } else {
                guard let proof = sign(PayApproval.proofHash(i)) else { throw APIError.message("Pip could not sign here. Nothing was sent.") }
                u = try await api.unsignedPay(i, approverKey: nil, proof: proof)
                guard !Task.isCancelled else { return }
                if u.requoted == true {
                    // A new price: show the new card. It needs its own approval.
                    guard let card = u.xchain, card.approvable else {
                        payPanel?.phase = .failed("The new price could not be checked. Nothing was sent.")
                        return
                    }
                    var next = payPanel ?? p
                    next.intent = u.intent(updating: i)
                    next.xchain = card
                    next.pending = u
                    next.phase = .ready
                    next.note = nil
                    payPanel = next
                    return
                }
            }
            i = p.pending.map { $0.intent(updating: i) } ?? i
            guard case .success(let ok) = PayTxCheck.check(u, intent: i, account: account, xchain: p.xchain) else {
                payPanel?.phase = .failed(PayTxCheck.refusedLine)
                Task { _ = try? await api.rejectPay(i.id) }
                return
            }
            guard let sig = sign(ok.hash) else { throw APIError.message("Pip could not sign here. Nothing was sent.") }
            let done = try await api.submitPay(i.id, signature: sig)
            guard !Task.isCancelled else { return }
            finishKeyboardSend(done)
        } catch {
            guard !Task.isCancelled else { return }
            payPanel?.phase = .ready
            payPanel?.note = plainLine(error)
        }
    }

    private func finishKeyboardSend(_ done: PayIntent) {
        deps.store.payPending = nil
        guard var p = payPanel else { return }
        p.intent = done
        p.pending = nil
        switch done.status {
        case "sent":
            p.phase = .sent
            if p.xchain != nil { p.swap = .swapping }
        case "failed": p.phase = .failed("It did not go through. Nothing left your wallet.")
        default: p.phase = .failed("Not confirmed yet. Check the link on NearBlocks.")
        }
        payPanel = p
        if p.swap != nil { pollSwap(done.id) }
    }

    /// Cross-chain after the deposit: asks where the swap is until it lands, is refunded or fails.
    private func pollSwap(_ id: String) {
        let api = deps.api(), every = Self.swapPollEvery
        payTask = Task { [weak self] in
            for _ in 0..<200 {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                guard let s = try? await api.xchainStatus(id), let state = SwapState(s) else { continue }
                guard let self, !Task.isCancelled, self.payPanel?.intent.id == id else { return }
                self.payPanel?.swap = state
                return
            }
        }
    }

    func rejectPayInKeyboard() {
        guard let p = payPanel, p.phase == .ready else { closePayPanel(); return }
        host?.playClick()
        let api = deps.api()
        deps.store.payPending = nil
        payPanel = nil
        bar = .done("Declined. Nothing was sent.")
        if !p.intent.id.isEmpty { Task { _ = try? await api.rejectPay(p.intent.id) } }
    }

    /// "Insert in chat" on the sent card.
    func insertKeyboardSent() {
        guard let p = payPanel, p.phase == .sent else { return }
        payPanel = nil
        if let card = p.xchain, let n = card.numbers, let d = card.destination {
            guard case .delivered(let url) = p.swap else { return }
            paySent = PaySent(id: p.intent.id, label: "Sent \(n.amount_out.text) \(n.amount_out.symbol) on \(d.chain_name)",
                              line: "Sent you \(n.amount_out.text) \(n.amount_out.symbol) on \(d.chain_name) \u{2713}" + (url.map { " \($0)" } ?? ""),
                              at: deps.now())
        } else {
            paySent = PaySent(p.intent, at: deps.now())
        }
        insertPaid()
    }

    func closePayPanel() {
        host?.playClick()
        payTask?.cancel()
        payPanel = nil
    }

    /// The app wrote a sent payment: offer its line for a while, once.
    func reloadPaySent() {
        guard let s = deps.store.paySent else { paySent = nil; return }
        if deps.now().timeIntervalSince(s.at) > PaySent.life {
            dropPaySent()
        } else if paySent != s {
            paySent = s
            bar = .idle
        }
    }

    func insertPaid() {
        guard let s = paySent, let host else { return }
        host.playClick()
        let before = host.contextBeforeInput ?? ""
        // A payment typed in the field ("send 5 USDC to ana.testnet") is replaced by its receipt.
        if let d = PayDetect.detect(before), before.hasSuffix(d.trigger) {
            for _ in 0..<d.trigger.count { host.deleteBackward() }
        } else if let w = XchainDetect.candidate(before), before.hasSuffix(w) {
            for _ in 0..<w.count { host.deleteBackward() }
        }
        let now = host.contextBeforeInput ?? ""
        host.insert((now.isEmpty || now.last?.isWhitespace == true ? "" : " ") + s.line)
        dropPaySent()
        textChanged()
    }

    func dropPaySent() {
        if paySent != nil { paySent = nil }
        if deps.store.paySent != nil { deps.store.paySent = nil }
    }
}

/// The card's lines when the keyboard cannot approve by itself.
enum PayFallback {
    static let useApp = "Approve this payment in \(AppConfig.displayName)."
    static let setPIN = "Set a payment PIN in \(AppConfig.displayName): Pip Pay > Payment PIN."
    static let pinSetupLink = "pip://pin-setup"
    static let locked = "Too many tries. Open \(AppConfig.displayName) to unlock."
}
