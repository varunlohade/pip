import Foundation

/// Which of today's appointments the bar offers. Pure: the caller passes the time.
enum AppointmentRules {
    static func nextUp(_ list: [Appointment], now: Date) -> Appointment? {
        list.first { $0.start > now }
    }
}
