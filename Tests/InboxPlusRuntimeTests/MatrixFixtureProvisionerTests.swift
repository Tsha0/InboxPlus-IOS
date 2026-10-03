import Foundation
import Testing
@testable import InboxPlusRuntime

@Test func sameSeedProducesSameRoomAliases() throws {
    let provisioner = try makeProvisioner()
    let first = provisioner.plan(seed: 42, roomCount: 2_000)
    let second = provisioner.plan(seed: 42, roomCount: 2_000)
    #expect(first.roomAliases == second.roomAliases)
}

@Test func differentSeedsProduceDifferentRoomAliases() throws {
    let provisioner = try makeProvisioner()
    let first = provisioner.plan(seed: 42, roomCount: 64)
    let second = provisioner.plan(seed: 43, roomCount: 64)
    #expect(first.roomAliases != second.roomAliases)
}

@Test func planProducesExactlyTheRequestedRoomCount() throws {
    let provisioner = try makeProvisioner()
    #expect(provisioner.plan(seed: 7, roomCount: 2_000).roomAliases.count == 2_000)
}

@Test func planAliasesAreUnique() throws {
    let provisioner = try makeProvisioner()
    let aliases = provisioner.plan(seed: 7, roomCount: 2_000).roomAliases
    #expect(Set(aliases).count == aliases.count)
}

@Test func planAliasesAreValidLocalparts() throws {
    let provisioner = try makeProvisioner()
    for alias in provisioner.plan(seed: 7, roomCount: 128).roomAliases {
        #expect(alias.range(of: "^[a-z0-9._-]+$", options: .regularExpression) != nil)
    }
}

@Test func planRecordsItsSeed() throws {
    let provisioner = try makeProvisioner()
    #expect(provisioner.plan(seed: 20_260_813, roomCount: 4).seed == 20_260_813)
}

@Test func deterministicTransactionIdentifiersAreStablePerRoomAndIndex() throws {
    let first = MatrixFixturePlan.transactionIdentifier(seed: 42, roomIndex: 3, messageIndex: 9)
    let second = MatrixFixturePlan.transactionIdentifier(seed: 42, roomIndex: 3, messageIndex: 9)
    #expect(first == second)
}

@Test func deterministicTransactionIdentifiersDifferAcrossMessages() throws {
    let first = MatrixFixturePlan.transactionIdentifier(seed: 42, roomIndex: 3, messageIndex: 9)
    let second = MatrixFixturePlan.transactionIdentifier(seed: 42, roomIndex: 3, messageIndex: 10)
    let third = MatrixFixturePlan.transactionIdentifier(seed: 42, roomIndex: 4, messageIndex: 9)
    #expect(first != second)
    #expect(first != third)
}

@Test func fixtureContextRoundTripsThroughCoding() throws {
    let context = FixtureContext(
        seed: 42,
        userID: "@bench:inboxplus.localhost",
        accessToken: "token",
        deviceID: "DEVICE",
        roomIDs: ["!a:inboxplus.localhost", "!b:inboxplus.localhost"]
    )
    let data = try JSONEncoder().encode(context)
    #expect(try JSONDecoder().decode(FixtureContext.self, from: data) == context)
}

private func makeProvisioner() throws -> MatrixFixtureProvisioner {
    try MatrixFixtureProvisioner(
        baseURL: URL(string: "http://127.0.0.1:18008")!,
        serverName: "inboxplus.localhost",
        registrationSecret: "shared-secret"
    )
}
