import Foundation

/// Drives the benchmark against a live loopback Synapse over the Matrix client-server API.
public struct LiveBenchmarkOperations: BenchmarkMatrixOperations {
    private let client: MatrixHTTPClient
    private let rooms: [String]

    public init(client: MatrixHTTPClient, rooms: [String]) {
        self.client = client
        self.rooms = rooms
    }

    public func createdRoomIDs() async throws -> [String] { rooms }

    public func sendMessage(
        roomID: String,
        transactionID: String,
        body: String
    ) async throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "msgtype": "m.text",
            "body": body,
        ])
        // A fixed transaction ID makes the retry inside the client safe: Synapse deduplicates.
        let response: SendEventResponse = try await client.send(
            .put,
            path: ["_matrix", "client", "v3", "rooms", roomID, "send", "m.room.message", transactionID],
            body: payload,
            idempotent: true
        )
        return response.eventID
    }

    public func readTimeline(roomID: String, limit: Int) async throws -> Int {
        let response: MessagesResponse = try await client.send(
            .get,
            path: ["_matrix", "client", "v3", "rooms", roomID, "messages"],
            query: [
                URLQueryItem(name: "dir", value: "b"),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            idempotent: true
        )
        return response.chunk.count
    }

    public func search(term: String) async throws -> Int {
        let payload = try JSONSerialization.data(withJSONObject: [
            "search_categories": [
                "room_events": [
                    "search_term": term,
                    "order_by": "recent",
                ],
            ],
        ])
        let response: SearchResponse = try await client.send(
            .post,
            path: ["_matrix", "client", "v3", "search"],
            body: payload
        )
        return response.matchCount
    }

    public func mediaMetadata(index: Int) async throws -> Int {
        let response: MediaConfigResponse = try await client.send(
            .get,
            path: ["_matrix", "client", "v1", "media", "config"],
            idempotent: true
        )
        return response.uploadSize ?? 0
    }

    public func eventIDs(inRoom roomID: String) async throws -> [String] {
        var eventIDs: [String] = []
        var from: String?
        // Page through the whole timeline: reconciliation must see every committed event.
        while true {
            var query = [
                URLQueryItem(name: "dir", value: "b"),
                URLQueryItem(name: "limit", value: "500"),
            ]
            if let from { query.append(URLQueryItem(name: "from", value: from)) }
            let response: MessagesResponse = try await client.send(
                .get,
                path: ["_matrix", "client", "v3", "rooms", roomID, "messages"],
                query: query,
                idempotent: true
            )
            eventIDs.append(
                contentsOf: response.chunk
                    .filter { $0.type == "m.room.message" }
                    .map(\.eventID)
            )
            guard let end = response.end, !end.isEmpty, !response.chunk.isEmpty else { break }
            from = end
        }
        return eventIDs
    }
}

private struct SendEventResponse: Decodable {
    let eventID: String
    private enum CodingKeys: String, CodingKey { case eventID = "event_id" }
}

private struct MessagesResponse: Decodable {
    let chunk: [TimelineEvent]
    let end: String?

    struct TimelineEvent: Decodable {
        let eventID: String
        let type: String
        private enum CodingKeys: String, CodingKey {
            case eventID = "event_id"
            case type
        }
    }
}

private struct SearchResponse: Decodable {
    let searchCategories: Categories

    struct Categories: Decodable {
        let roomEvents: Results

        struct Results: Decodable {
            let count: Int?
        }

        private enum CodingKeys: String, CodingKey { case roomEvents = "room_events" }
    }

    private enum CodingKeys: String, CodingKey { case searchCategories = "search_categories" }

    var matchCount: Int { searchCategories.roomEvents.count ?? 0 }
}

private struct MediaConfigResponse: Decodable {
    let uploadSize: Int?
    private enum CodingKeys: String, CodingKey { case uploadSize = "m.upload.size" }
}
