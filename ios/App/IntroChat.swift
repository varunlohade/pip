import SwiftUI
import UIKit

// The chats the intro plays in. Each one follows the look of a well-known chat app: its colours, bubble shape,
// header and message field. Everything is drawn here. There is no logo, no app icon and no image from those apps.

enum ChatLine: Equatable {
    case them(String)
    case me(String)
    /// A quiet time label, like "9 days ago".
    case stamp(String)
}

struct ChatSkin {
    enum Kind { case iMessage, telegram, marketplace, whatsApp, instagram }
    enum Tail { case none, hook, wedge }

    let kind: Kind
    /// The name in the caption: "In WhatsApp".
    let app: String
    let wall: Color
    /// The colour of the drawn wallpaper pattern. Nil for a plain wall.
    let doodle: Color?
    let bar: Color
    let mine: [Color]
    let mineText: Color
    let theirs: Color
    let accent: Color
    let radius: CGFloat
    let tail: Tail
    /// Time and ticks sit inside the bubble.
    let ticks: Color?
    let placeholder: String
    let fontSize: CGFloat

    static func tint(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    private static let plainWall = tint(0xFFFFFF, 0x000000)

    static let iMessage = ChatSkin(kind: .iMessage, app: "iMessage", wall: plainWall, doodle: nil, bar: tint(0xF6F6F6, 0x1C1C1E),
                                   mine: [tint(0x0A84FF, 0x0A84FF)], mineText: .white, theirs: tint(0xE9E9EB, 0x26262A), accent: tint(0x007AFF, 0x0A84FF),
                                   radius: 18, tail: .hook, ticks: nil, placeholder: "iMessage", fontSize: 17)
    static let telegram = ChatSkin(kind: .telegram, app: "Telegram", wall: tint(0xC4DAEC, 0x0E1621), doodle: tint(0xAFCBE2, 0x16222F), bar: tint(0xF7F7F7, 0x17212B),
                                   mine: [tint(0xD3EBFF, 0x2B5278)], mineText: tint(0x000000, 0xFFFFFF), theirs: tint(0xFFFFFF, 0x182533), accent: tint(0x2AABEE, 0x6AB3F3),
                                   radius: 16, tail: .hook, ticks: tint(0x3E9BE0, 0x6AB3F3), placeholder: "Message", fontSize: 16)
    static let marketplace = ChatSkin(kind: .marketplace, app: "Facebook Marketplace", wall: plainWall, doodle: nil, bar: tint(0xFFFFFF, 0x000000),
                                      mine: [tint(0x0084FF, 0x0084FF)], mineText: .white, theirs: tint(0xF0F0F0, 0x303030), accent: tint(0x0084FF, 0x0084FF),
                                      radius: 18, tail: .none, ticks: nil, placeholder: "Aa", fontSize: 16)
    static let whatsApp = ChatSkin(kind: .whatsApp, app: "WhatsApp", wall: tint(0xEFE7DE, 0x0B141A), doodle: tint(0xDDD3C6, 0x15222A), bar: tint(0xF6F6F6, 0x1F2C34),
                                   mine: [tint(0xD9FDD3, 0x005C4B)], mineText: tint(0x111B21, 0xE9EDEF), theirs: tint(0xFFFFFF, 0x1F2C34), accent: tint(0x1DAA61, 0x21C063),
                                   radius: 9, tail: .wedge, ticks: tint(0x53BDEB, 0x53BDEB), placeholder: "Message", fontSize: 16)
    static let instagram = ChatSkin(kind: .instagram, app: "Instagram", wall: plainWall, doodle: nil, bar: tint(0xFFFFFF, 0x000000),
                                    mine: [Color(hex: 0xA033FF), Color(hex: 0x6A4DF5), Color(hex: 0x3797F0)], mineText: .white, theirs: tint(0xEFEFEF, 0x262626),
                                    accent: tint(0x3797F0, 0x3797F0), radius: 22, tail: .none, ticks: nil, placeholder: "Message\u{2026}", fontSize: 16)
}

/// A message bubble. `hook` is a curved tail at the bottom corner; `wedge` is a small corner at the top.
struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 6
    let radius: CGFloat
    let tail: ChatSkin.Tail
    let mine: Bool

    func path(in rect: CGRect) -> Path {
        let t = tail == .none ? 0 : Self.tailWidth
        let body = CGRect(x: rect.minX + (mine ? 0 : t), y: rect.minY, width: rect.width - t, height: rect.height)
        var p = Path(roundedRect: body, cornerRadius: min(radius, body.height / 2), style: .continuous)
        // The tail is drawn for a bubble on the right, then mirrored for one on the left.
        var tailPath = Path()
        let x = body.maxX
        switch tail {
        case .none: break
        case .hook:
            tailPath.move(to: CGPoint(x: x - 6, y: rect.maxY - 12))
            tailPath.addQuadCurve(to: CGPoint(x: x + t, y: rect.maxY), control: CGPoint(x: x, y: rect.maxY - 2))
            tailPath.addQuadCurve(to: CGPoint(x: x - 12, y: rect.maxY - 4), control: CGPoint(x: x - 3, y: rect.maxY + 1))
            tailPath.closeSubpath()
        case .wedge:
            tailPath.move(to: CGPoint(x: x - radius, y: rect.minY))
            tailPath.addLine(to: CGPoint(x: x + t, y: rect.minY))
            tailPath.addLine(to: CGPoint(x: x, y: rect.minY + 10))
            tailPath.addLine(to: CGPoint(x: x - radius, y: rect.minY + radius))
            tailPath.closeSubpath()
        }
        if !mine {
            let flip = CGAffineTransform(translationX: body.minX + body.maxX, y: 0).scaledBy(x: -1, y: 1)
            tailPath = tailPath.applying(flip)
        }
        p.addPath(tailPath)
        return p
    }
}

/// A chat wallpaper drawn from simple line shapes. It is our own pattern.
struct DoodleWall: View {
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 46
            var seed: UInt64 = 11
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 1000) / 1000
            }
            for row in 0...Int(size.height / step) + 1 {
                for col in 0...Int(size.width / step) + 1 {
                    let c = CGPoint(x: CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2) + rnd() * 10 - 5, y: CGFloat(row) * step + rnd() * 10 - 5)
                    let s = 7 + rnd() * 4
                    var p = Path()
                    switch (row * 5 + col * 3) % 7 {
                    case 0: p.addEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
                    case 1:
                        p.move(to: CGPoint(x: c.x - s, y: c.y)); p.addLine(to: CGPoint(x: c.x + s, y: c.y))
                        p.move(to: CGPoint(x: c.x, y: c.y - s)); p.addLine(to: CGPoint(x: c.x, y: c.y + s))
                    case 2:
                        p.move(to: CGPoint(x: c.x, y: c.y - s)); p.addLine(to: CGPoint(x: c.x + s, y: c.y + s)); p.addLine(to: CGPoint(x: c.x - s, y: c.y + s)); p.closeSubpath()
                    case 3:
                        p.move(to: CGPoint(x: c.x - s, y: c.y))
                        p.addCurve(to: CGPoint(x: c.x + s, y: c.y), control1: CGPoint(x: c.x - s / 2, y: c.y - s * 1.6), control2: CGPoint(x: c.x + s / 2, y: c.y + s * 1.6))
                    case 4: p.addRoundedRect(in: CGRect(x: c.x - s, y: c.y - s * 0.7, width: 2 * s, height: 1.4 * s), cornerSize: CGSize(width: 3, height: 3))
                    case 5:
                        for i in 0..<5 {
                            let a = CGFloat(i) * 4 * .pi / 5 - .pi / 2
                            let pt = CGPoint(x: c.x + cos(a) * s, y: c.y + sin(a) * s)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        p.closeSubpath()
                    default: p.addArc(center: c, radius: s, startAngle: .degrees(20), endAngle: .degrees(200), clockwise: false)
                    }
                    ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

/// One chat: the header, the messages, and the message field the keyboard types into.
struct ChatView: View {
    let skin: ChatSkin
    let contact: String
    let lines: [ChatLine]
    /// Messages the owner sent in this scene.
    let sent: [String]
    /// The text in the message field.
    let draft: String

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: skin.kind == .iMessage ? Theme.Space.xs : 6) {
                Spacer(minLength: 0)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in bubble(line) }
                ForEach(Array(sent.enumerated()), id: \.offset) { _, text in
                    bubble(.me(text)).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Theme.Space.xs)
            .padding(.bottom, Theme.Space.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            composer
        }
        .background {
            ZStack {
                skin.wall
                if let ink = skin.doodle { DoodleWall(ink: ink) }
            }
        }
    }

    // MARK: header

    private func avatar(_ size: CGFloat) -> some View {
        let colors: [Color] = switch skin.kind {
        case .iMessage: [Color(hex: 0xA5ABB8), Color(hex: 0x858994)]
        case .telegram: [Color(hex: 0x72D5FD), Color(hex: 0x2A9EF1)]
        case .whatsApp: [Color(hex: 0xDFE5E7), Color(hex: 0xC8D0D4)]
        case .marketplace: [Color(hex: 0xC9CCD1), Color(hex: 0xA8ABB0)]
        case .instagram: [Color(hex: 0xFEDA75), Color(hex: 0xD62976)]
        }
        return Text(contact.prefix(1)).font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Circle())
    }

    private func icon(_ name: String, _ size: CGFloat = 19, color: Color? = nil) -> some View {
        Image(systemName: name).font(.system(size: size, weight: .regular)).foregroundStyle(color ?? skin.accent)
    }

    private var back: some View { icon("chevron.left", 19, color: skin.kind == .whatsApp || skin.kind == .instagram ? Theme.Color.text1 : skin.accent).fontWeight(.medium) }

    @ViewBuilder private var header: some View {
        switch skin.kind {
        case .iMessage:
            ZStack {
                HStack { back; Spacer(); icon("video", 20) }
                VStack(spacing: 2) {
                    avatar(38)
                    HStack(spacing: 2) {
                        Text(contact).font(.system(size: 11)).foregroundStyle(Theme.Color.text1)
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(Theme.Color.text3)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            .background(skin.bar)
        case .telegram:
            ZStack {
                HStack { back; Spacer(); avatar(36) }
                VStack(spacing: 1) {
                    Text(contact).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                    Text("last seen recently").font(.system(size: 12)).foregroundStyle(Theme.Color.text2)
                }
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(skin.bar)
        case .whatsApp:
            HStack(spacing: Theme.Space.xs) {
                back
                avatar(36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                    Text("online").font(.system(size: 12)).foregroundStyle(Theme.Color.text2)
                }
                Spacer()
                icon("video", 19, color: Theme.Color.text1)
                icon("phone", 18, color: Theme.Color.text1).padding(.leading, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(skin.bar)
        case .marketplace:
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    back
                    avatar(32)
                    Text(contact).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                    Spacer()
                    icon("phone.fill", 17)
                    icon("info.circle.fill", 19).padding(.leading, Theme.Space.xs)
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
                // The listing this chat is about: a photo placeholder, the title and the price.
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "lamp.desk.fill").font(.system(size: 20)).foregroundStyle(Theme.Color.text2)
                        .frame(width: 44, height: 44)
                        .background(skin.theirs, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Desk lamp").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                        Text("$45 \u{00B7} Listed on Marketplace").font(.system(size: 13)).foregroundStyle(Theme.Color.text2)
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.xs)
            }
            .background(skin.bar)
        case .instagram:
            HStack(spacing: Theme.Space.xs) {
                back
                avatar(32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.Color.text1)
                    Text(contact.lowercased() + ".cuts").font(.system(size: 12)).foregroundStyle(Theme.Color.text2)
                }
                Spacer()
                icon("phone", 19, color: Theme.Color.text1)
                icon("video", 20, color: Theme.Color.text1).padding(.leading, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .background(skin.bar)
        }
    }

    // MARK: bubbles

    @ViewBuilder private func bubble(_ line: ChatLine) -> some View {
        switch line {
        case .stamp(let text):
            if skin.doodle != nil {
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Color.text2)
                    .padding(.horizontal, Theme.Space.xs).padding(.vertical, 3)
                    .background(skin.theirs.opacity(0.9), in: Capsule())
                    .frame(maxWidth: .infinity)
            } else {
                Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Color.text2).frame(maxWidth: .infinity)
            }
        case .them(let text):
            // The Marketplace buyer's first message is the ready-made question: a pill.
            content(text, mine: false).foregroundStyle(Theme.Color.text1)
                .background(skin.theirs, in: BubbleShape(radius: skin.radius, tail: skin.tail, mine: false))
                .padding(.trailing, Theme.Space.xxl).frame(maxWidth: .infinity, alignment: .leading)
        case .me(let text):
            content(text, mine: true).foregroundStyle(skin.mineText).tint(skin.mineText)
                .background(LinearGradient(colors: skin.mine, startPoint: .top, endPoint: .bottom), in: BubbleShape(radius: skin.radius, tail: skin.tail, mine: true))
                .padding(.leading, Theme.Space.xxl).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func content(_ text: String, mine: Bool) -> some View {
        let tail = skin.tail == .none ? 0 : BubbleShape.tailWidth
        return VStack(alignment: .trailing, spacing: 1) {
            Text(text).font(.system(size: skin.fontSize)).lineLimit(4)
            if let ticks = skin.ticks {
                HStack(spacing: 3) {
                    Text("4:06 PM").font(.system(size: 11))
                        .foregroundStyle(mine ? skin.mineText.opacity(0.55) : Theme.Color.text2)
                    if mine {
                        // Two ticks: delivered and read.
                        ZStack {
                            Image(systemName: "checkmark").offset(x: -2.5)
                            Image(systemName: "checkmark").offset(x: 2.5)
                        }
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(ticks).frame(width: 16)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, skin.ticks == nil ? Theme.Space.xs : 6)
        .padding(mine ? .trailing : .leading, tail)
    }

    // MARK: message field

    private var typed: some View {
        Text(draft.isEmpty ? skin.placeholder : draft)
            .font(.system(size: skin.fontSize))
            .foregroundStyle(draft.isEmpty ? Theme.Color.text3 : Theme.Color.text1)
            .lineLimit(3).truncationMode(.head)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .accessibilityIdentifier("intro.message")
    }

    private func sendButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(skin.accent, in: Circle())
    }

    @ViewBuilder private var composer: some View {
        let empty = draft.isEmpty
        HStack(alignment: .bottom, spacing: Theme.Space.xs) {
            switch skin.kind {
            case .iMessage:
                icon("plus", 15, color: Theme.Color.text2).fontWeight(.semibold).frame(width: 32, height: 32).background(skin.theirs, in: Circle())
                HStack(alignment: .bottom, spacing: Theme.Space.xxs) {
                    typed
                    if empty { icon("mic", 16, color: Theme.Color.text3).frame(height: 22) } else { sendButton("arrow.up").offset(x: 6, y: 3) }
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.Color.hairline, lineWidth: 1))
            case .telegram:
                icon("paperclip", 20, color: Theme.Color.text2).frame(height: 32)
                typed.padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                    .background(skin.theirs, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.Color.edge, lineWidth: 1))
                if empty { icon("mic", 20, color: Theme.Color.text2).frame(height: 32) } else { sendButton("arrow.up").padding(.bottom, 2) }
            case .whatsApp:
                icon("plus", 21, color: Theme.Color.text1).frame(height: 32)
                typed.padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                    .background(skin.theirs, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                if empty {
                    icon("camera", 19, color: Theme.Color.text1).frame(height: 32)
                    icon("mic", 19, color: Theme.Color.text1).frame(height: 32)
                } else { sendButton("paperplane.fill").padding(.bottom, 2) }
            case .marketplace:
                icon("plus.circle.fill", 22).frame(height: 32)
                if empty { icon("camera.fill", 19).frame(height: 32); icon("photo", 19).frame(height: 32) }
                typed.padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                    .background(skin.theirs, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                icon(empty ? "hand.thumbsup.fill" : "paperplane.fill", 20).frame(height: 32)
            case .instagram:
                HStack(alignment: .bottom, spacing: Theme.Space.xs) {
                    Image(systemName: "camera.fill").font(.system(size: 14)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(skin.accent, in: Circle())
                    typed.padding(.vertical, 5)
                    if empty {
                        icon("mic", 19, color: Theme.Color.text1).frame(height: 32)
                        icon("photo", 19, color: Theme.Color.text1).frame(height: 32)
                    } else {
                        Text("Send").font(.system(size: 16, weight: .semibold)).foregroundStyle(skin.accent).frame(height: 32)
                    }
                }
                .padding(.leading, 5).padding(.trailing, Theme.Space.s).padding(.vertical, 5)
                .background(skin.theirs, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, 6)
        .background(skin.doodle == nil ? skin.wall : skin.bar)
    }
}
