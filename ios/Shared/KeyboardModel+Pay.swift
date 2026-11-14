import Foundation

/// The keyboard's approval card: one payment, where it is, and what the keyboard may still send today.
struct PayPanel: Equatable {
    var intent: PayIntent
    var phase: PayPhase = .ready
    /// One quiet line, such as "Not approved. Nothing was sent."
    var note: String?
    /// After a send: what is left for keyboard sends today, in the intent's token.
    var leftAfter: String?
}

/// Type-to-pay in the keyboard (design C). The keyboard proposes a payment on the server. If keyboard pay is set up, the
/// recipient was paid before and the amount fits the keyboard's daily limit, the keyboard shows its own card and sends
/// after Face ID with the capped keyboard key. Anything else opens the app, which alone holds the full approver key.
extension KeyboardModel {
    /// Reads a payment from the text. True when one shows, so the sentence does not also go to /v1/suggest.
    func updatePay(_ text: String, quiet: Bool) -> Bool {
        let found = PayDetect.detect(text)
        // Text with no payment ends the "already proposed" memory, so the same payment typed again offers the chip again.
        if found == nil, !payDone.isEmpty { payDone = [] }
        guard !quiet, payPanel == nil, let d = found, !payDone.contains(d) else {
            if payOffer != nil { payOffer = nil }
            return false
        }
        if payOffer != d { payOffer = d }
        return true
    }

    var payItem: BarItems.Item? {
        payOffer.map { BarItems.Item(id: "pay", title: $0.label, detail: "Approve", action: .pay, trigger: $0.trigger) }
    }

    var paidItem: BarItems.Item? {
        paySent.map { BarItems.Item(id: "paid", title: $0.label, detail: $0.line, tone: .success) }
    }

    /// Tap on the chip: the server keeps the exact fields for 10 minutes and says whether the keyboard may send them.
    func tapPay() {
        guard let d = payOffer else { return }
        host?.playClick()
        payTask?.cancel()
        payDone.insert(d)
        payOffer = nil
        bar = .working("Getting it ready\u{2026}")
        let api = deps.api()
        payTask = Task { [weak self] in
            do {
                let intent = try await api.createPayIntent(d)
                guard let self, !Task.isCancelled else { return }
                self.deps.store.payPending = intent.id
                if intent.keyboard?.ok == true, self.deps.store.payKeyboardKey != nil {
                    self.bar = .idle
                    self.notesOpen = false
                    self.writeOpen = false
                    self.payPanel = PayPanel(intent: intent)
                } else {
                    self.openAppToApprove(intent)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.payDone.remove(d)
                self.bar = .error(plainLine(error))
            }
        }
    }

    /// New recipient, over the limit, no keyboard key, or no Face ID here: the app shows its full approval card.
    func openAppToApprove(_ intent: PayIntent) {
        payPanel = nil
        let opened = URL(string: intent.deep_link).map { host?.open($0) ?? false } ?? false
        bar = .done(opened ? "Opening \(AppConfig.displayName)\u{2026}" : "Open \(AppConfig.displayName) to approve")
    }

    /// "Approve with Face ID" on the keyboard card.
    func approvePayInKeyboard() {
        guard var p = payPanel, p.phase == .ready, let key = deps.store.payKeyboardKey else { return }
        host?.playClick()
        p.phase = .approving
        p.note = nil
        payPanel = p
        let i = p.intent
        let api = deps.api(), auth = deps.auth(), faceID = deps.store.payFaceID
        payTask = Task { [weak self] in
            if faceID {
                let r = await auth.confirm("Send \(i.amount) \(i.token) to \(i.recipient)")
                guard let self, !Task.isCancelled else { return }
                switch r {
                case .approved: break
                case .denied:
                    self.payPanel?.phase = .ready
                    self.payPanel?.note = "Not approved. Nothing was sent."
                    return
                case .unavailable:
                    self.openAppToApprove(i)
                    return
                }
            }
            do {
                let done = try await api.keyboardApprovePay(i, keyboardKey: key)
                guard let self, !Task.isCancelled else { return }
                self.finishKeyboardSend(done, left: i.keyboard?.left)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if needsApp(error) { self.openAppToApprove(i); return }
                self.payPanel?.phase = .ready
                self.payPanel?.note = plainLine(error)
            }
        }
    }

    private func finishKeyboardSend(_ done: PayIntent, left: String?) {
        deps.store.payPending = nil
        guard var p = payPanel else { return }
        p.intent = done
        switch done.status {
        case "sent":
            p.phase = .sent
            if let l = left.flatMap({ Decimal(string: $0) }), let a = Decimal(string: done.amount) {
                p.leftAfter = "\(max(l - a, 0))"
            }
        case "failed": p.phase = .failed("It did not go through. Nothing left your wallet.")
        default: p.phase = .failed("Not confirmed yet. Check the link on NearBlocks.")
        }
        payPanel = p
    }

    func rejectPayInKeyboard() {
        guard let p = payPanel, p.phase == .ready else { closePayPanel(); return }
        host?.playClick()
        let api = deps.api()
        deps.store.payPending = nil
        payPanel = nil
        bar = .done("Declined. Nothing was sent.")
        Task { _ = try? await api.rejectPay(p.intent.id) }
    }

    /// "Insert in chat" on the sent card.
    func insertKeyboardSent() {
        guard let p = payPanel, p.phase == .sent else { return }
        payPanel = nil
        paySent = PaySent(p.intent, at: deps.now())
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
