import Foundation
import Testing
@testable import InboxPlusIMessage

/// Builds a database with the same schema and quirks as the real one, using the `sqlite3` tool so
/// the fixture is defined by SQL rather than by the code under test.
private func makeDatabase(_ statements: String) throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/IMessageStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chat.db")

    let schema = """
    CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL,
        country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT);
    CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
        style INTEGER, state INTEGER, chat_identifier TEXT, service_name TEXT,
        room_name TEXT, display_name TEXT);
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
        text TEXT, handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER,
        is_from_me INTEGER DEFAULT 0, attributedBody BLOB, associated_message_guid TEXT);
    CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER,
        PRIMARY KEY (chat_id, message_id));
    CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL,
        filename TEXT, mime_type TEXT);
    CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER,
        PRIMARY KEY (message_id, attachment_id));
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    input.fileHandleForWriting.write(Data((schema + "\n" + statements + "\n").utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return url
}

private func cleanUp(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// 2024-03-01T12:00:00Z as nanoseconds since 2001, which is what current macOS writes.
private let nanoseconds = "731_160_000_000_000_000".replacingOccurrences(of: "_", with: "")

@Test func chatsAreReadWithTheirAddressingIdentity() throws {
    let url = try makeDatabase("""
    INSERT INTO chat (guid, style, chat_identifier, service_name, display_name)
      VALUES ('iMessage;-;+15555550123', 45, '+15555550123', 'iMessage', NULL);
    INSERT INTO chat (guid, style, chat_identifier, service_name, display_name)
      VALUES ('iMessage;+;chat99', 43, 'chat99', 'iMessage', 'Weekend Trip');
    """)
    defer { cleanUp(url) }

    let chats = try IMessageStore(url: url).chats()
    #expect(chats.count == 2)
    #expect(chats[0].guid == "iMessage;-;+15555550123")
    #expect(chats[0].identifier == "+15555550123")
    #expect(!chats[0].isGroup)
    // Style 43 is a group, which decides whether a reply addresses a room or a person.
    #expect(chats[1].isGroup)
    #expect(chats[1].displayName == "Weekend Trip")
}

@Test func messagesAreReadWithSenderAndDirection() throws {
    let url = try makeDatabase("""
    INSERT INTO handle (id, service) VALUES ('+15555550123', 'iMessage');
    INSERT INTO chat (guid, style, chat_identifier, service_name)
      VALUES ('iMessage;-;+15555550123', 45, '+15555550123', 'iMessage');
    INSERT INTO message (guid, text, handle_id, date, is_from_me)
      VALUES ('m1', 'are you around?', 1, \(nanoseconds), 0);
    INSERT INTO message (guid, text, handle_id, date, is_from_me)
      VALUES ('m2', 'yes', 1, \(nanoseconds), 1);
    INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
    """)
    defer { cleanUp(url) }

    let rows = try IMessageStore(url: url).recentMessages()
    #expect(rows.count == 2)
    #expect(rows[0].body == "are you around?")
    #expect(rows[0].handle == "+15555550123")
    #expect(!rows[0].isFromMe)
    #expect(rows[1].isFromMe)
    #expect(rows[0].chatGUID == "iMessage;-;+15555550123")
    #expect(rows[0].date != nil)
}

@Test func aMessageWithOnlyAnAttributedBodyIsStillRead() throws {
    // Since macOS 11 `text` is frequently NULL and the body lives only in `attributedBody`. A
    // reader that ignores it shows a large part of a real conversation as empty.
    let blob = typedStream(containing: "sent from the new Messages")
    let hex = blob.map { String(format: "%02X", $0) }.joined()
    let url = try makeDatabase("""
    INSERT INTO chat (guid, style, chat_identifier, service_name)
      VALUES ('iMessage;-;a@b.com', 45, 'a@b.com', 'iMessage');
    INSERT INTO message (guid, text, handle_id, date, is_from_me, attributedBody)
      VALUES ('m1', NULL, 0, \(nanoseconds), 0, X'\(hex)');
    INSERT INTO chat_message_join VALUES (1, 1);
    """)
    defer { cleanUp(url) }

    let rows = try IMessageStore(url: url).recentMessages()
    #expect(rows.first?.text == nil)
    #expect(rows.first?.body == "sent from the new Messages")
}

@Test func reactionsAreNotShownAsSeparateMessages() throws {
    // A tapback is a message row pointing at another message; listing it would put "Liked "yes""
    // in the transcript as its own line.
    let url = try makeDatabase("""
    INSERT INTO chat (guid, style, chat_identifier, service_name)
      VALUES ('iMessage;-;a@b.com', 45, 'a@b.com', 'iMessage');
    INSERT INTO message (guid, text, handle_id, date, is_from_me, associated_message_guid)
      VALUES ('m1', 'hello', 0, \(nanoseconds), 0, NULL);
    INSERT INTO message (guid, text, handle_id, date, is_from_me, associated_message_guid)
      VALUES ('m2', 'Liked "hello"', 0, \(nanoseconds), 0, 'p:0/m1');
    INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
    """)
    defer { cleanUp(url) }

    let rows = try IMessageStore(url: url).recentMessages()
    #expect(rows.map(\.guid) == ["m1"])
}

@Test func attachmentCountsAreReported() throws {
    let url = try makeDatabase("""
    INSERT INTO chat (guid, style, chat_identifier, service_name)
      VALUES ('iMessage;-;a@b.com', 45, 'a@b.com', 'iMessage');
    INSERT INTO message (guid, text, handle_id, date, is_from_me)
      VALUES ('m1', NULL, 0, \(nanoseconds), 0);
    INSERT INTO chat_message_join VALUES (1, 1);
    INSERT INTO attachment (guid, filename, mime_type) VALUES ('a1', 'IMG_1.HEIC', 'image/heic');
    INSERT INTO message_attachment_join VALUES (1, 1);
    """)
    defer { cleanUp(url) }

    #expect(try IMessageStore(url: url).recentMessages().first?.attachmentCount == 1)
}

@Test func onlyMessagesAfterAWatermarkAreReturned() throws {
    let url = try makeDatabase("""
    INSERT INTO chat (guid, style, chat_identifier, service_name)
      VALUES ('iMessage;-;a@b.com', 45, 'a@b.com', 'iMessage');
    INSERT INTO message (guid, text, handle_id, date, is_from_me)
      VALUES ('m1', 'one', 0, \(nanoseconds), 0);
    INSERT INTO message (guid, text, handle_id, date, is_from_me)
      VALUES ('m2', 'two', 0, \(nanoseconds), 0);
    INSERT INTO chat_message_join VALUES (1, 1), (1, 2);
    """)
    defer { cleanUp(url) }

    let store = try IMessageStore(url: url)
    #expect(try store.maxMessageRowID() == 2)
    #expect(try store.messages(afterRowID: 1).map(\.guid) == ["m2"])
    #expect(try store.messages(afterRowID: 2).isEmpty)
}

@Test func aMissingDatabaseIsReportedClearly() {
    let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/chat.db")
    #expect(throws: IMessageStoreError.databaseMissing(missing.path)) {
        try IMessageStore(url: missing)
    }
}

// MARK: - Fixture helper

/// Builds a blob shaped like the archive Messages writes: the class name, a short run of type
/// bytes, `+`, a length, then the UTF-8 body.
func typedStream(containing text: String) -> [UInt8] {
    var bytes: [UInt8] = [0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64]
    bytes += Array("NSString".utf8)
    bytes += [0x01, 0x94, 0x84, 0x01]
    bytes += [0x2B]
    let payload = Array(text.utf8)
    if payload.count < 0x80 {
        bytes += [UInt8(payload.count)]
    } else {
        bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
    }
    bytes += payload
    return bytes
}
