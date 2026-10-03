import Foundation

public enum IMessageSendError: Error, Equatable, CustomStringConvertible {
    case automationDenied
    case messagesReportedFailure(String)
    case couldNotRunScript(String)

    public var description: String {
        switch self {
        case .automationDenied:
            "Inbox+ needs permission to control Messages. Grant it in System Settings › Privacy & "
                + "Security › Automation, then try again."
        case let .messagesReportedFailure(message):
            "Messages could not send this: \(message)"
        case let .couldNotRunScript(message):
            "Could not ask Messages to send: \(message)"
        }
    }
}

/// Sends an iMessage by asking Messages to send it.
///
/// There is no API for sending iMessage, and no credential Inbox+ could hold if there were. The only
/// supported route is an Apple event to Messages, which macOS gates behind Automation permission
/// and prompts for the first time one is sent.
public struct IMessageSender: Sendable {
    /// Injected so the script can be captured in tests without automating anything.
    private let run: @Sendable (String) throws -> String

    public init(run: (@Sendable (String) throws -> String)? = nil) {
        self.run = run ?? IMessageSender.runWithOSAScript
    }

    @discardableResult
    public func send(_ body: String, toChatGUID guid: String) throws -> String {
        try run(Self.script(body: body, chatGUID: guid))
    }

    /// Addresses the existing chat by its GUID rather than looking a buddy up by handle.
    ///
    /// A handle lookup picks a service for you and silently sends green-bubble SMS when the
    /// iMessage lookup misses. Targeting the chat that the message actually belongs to keeps the
    /// reply in the conversation the user is looking at.
    static func script(body: String, chatGUID: String) -> String {
        """
        tell application "Messages"
            set targetChat to a reference to chat id "\(escape(chatGUID))"
            send "\(escape(body))" to targetChat
        end tell
        """
    }

    /// AppleScript string literals only understand backslash escapes for a quote, a backslash and a
    /// newline. Anything unescaped ends the literal and the rest of the message becomes code.
    static func escape(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static let runWithOSAScript: @Sendable (String) throws -> String = { script in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw IMessageSendError.couldNotRunScript(error.localizedDescription)
        }
        process.waitUntilExit()

        let errorText = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            // -1743 is the specific refusal macOS returns when Automation has not been granted, and
            // it needs its own message because the fix is a settings change, not a retry.
            if errorText.contains("-1743") || errorText.lowercased().contains("not authorized") {
                throw IMessageSendError.automationDenied
            }
            throw IMessageSendError.messagesReportedFailure(errorText.isEmpty ? "unknown error" : errorText)
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
