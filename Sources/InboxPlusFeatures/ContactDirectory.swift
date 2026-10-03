import InboxPlusCore

public enum ContactDirectoryError: Error, Equatable {
    case duplicatePerson
    case missingPerson
    case identityAlreadyLinked
    case invalidInitialState
}

public struct ContactDirectory: Sendable {
    public private(set) var people: [String: InboxPlusPerson]
    public private(set) var links: [String: PersonLink]

    public init() {
        people = [:]
        links = [:]
    }

    public init(people: [String: InboxPlusPerson], links: [String: PersonLink]) throws {
        var linkedRemoteIdentityIDs = Set<String>()

        for (personID, person) in people {
            guard person.id == personID else { throw ContactDirectoryError.invalidInitialState }
        }

        for (personID, link) in links {
            guard people[personID] != nil, link.personID == personID else {
                throw ContactDirectoryError.invalidInitialState
            }
            for remoteIdentityID in link.remoteIdentityIDs {
                guard linkedRemoteIdentityIDs.insert(remoteIdentityID).inserted else {
                    throw ContactDirectoryError.invalidInitialState
                }
            }
        }

        self.people = people
        self.links = links
    }

    public mutating func createPerson(id: String, displayName: String) throws {
        guard people[id] == nil else { throw ContactDirectoryError.duplicatePerson }
        people[id] = InboxPlusPerson(id: id, displayName: displayName)
    }

    public mutating func link(remoteIdentityID: String, to personID: String) throws {
        guard people[personID] != nil else { throw ContactDirectoryError.missingPerson }
        guard self.personID(linkedTo: remoteIdentityID) == nil else {
            throw ContactDirectoryError.identityAlreadyLinked
        }
        var link = links[personID] ?? PersonLink(personID: personID, remoteIdentityIDs: [])
        link.remoteIdentityIDs.insert(remoteIdentityID)
        links[personID] = link
    }

    public mutating func unlink(remoteIdentityID: String, from personID: String) throws {
        guard var link = links[personID] else { throw ContactDirectoryError.missingPerson }
        link.remoteIdentityIDs.remove(remoteIdentityID)
        links[personID] = link
    }

    mutating func removePerson(id: String) {
        people[id] = nil
        links[id] = nil
    }

    public func personID(linkedTo remoteIdentityID: String) -> String? {
        links.values.first { $0.remoteIdentityIDs.contains(remoteIdentityID) }?.personID
    }
}
