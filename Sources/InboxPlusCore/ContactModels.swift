public struct InboxPlusPerson: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct PersonLink: Codable, Equatable, Sendable {
    public let personID: String
    public var remoteIdentityIDs: Set<String>

    public init(personID: String, remoteIdentityIDs: Set<String>) {
        self.personID = personID
        self.remoteIdentityIDs = remoteIdentityIDs
    }
}
