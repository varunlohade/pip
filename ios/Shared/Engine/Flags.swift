import Foundation

/// Work that ships dark until it is ready.
enum Flags {
    /// The jev router (/v1/route) in place of /v1/suggest, gated by the secret filter, with its "AI is off" line. On in 0.5.
    static var router = true
    /// The typing memory as router context. Off in 0.5; the unit tests turn it on.
    static var memory = false
    /// "$0.02 USDT" payments and the "Which chain?" chips. Off in 0.5; the unit tests turn it on.
    static var dollarPay = false
}
