import os

extension Logger {
    private static let subsystem = "com.jerickdev.yabaibar"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let yabai = Logger(subsystem: subsystem, category: "yabai")
    static let media = Logger(subsystem: subsystem, category: "media")
}
