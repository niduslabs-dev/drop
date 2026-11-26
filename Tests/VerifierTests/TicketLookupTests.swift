import Foundation
import Testing

@testable import Verifier

/// Reading Apple's ticket service replies, without the network.
@Suite struct TicketLookupTests {
    private let hash = CDHash(hashType: 2, bytes: [UInt8](repeating: 0xAB, count: CDHash.length))

    private func ticket(listing hashes: [CDHash]) throws -> NotarizationTicket {
        func le(_ value: Int, _ size: Int) -> [UInt8] {
            (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        var bytes = Array("s8ch".utf8) + le(1, 4) + le(0, 4) + le(24 + hashes.count * 21, 4)
        bytes += Array("g8tk".utf8) + le(2, 2) + le(20, 2) + le(hashes.count, 4) + le(0, 4) + le(1_700_000_000, 8)
        for hash in hashes { bytes += [hash.hashType] + hash.bytes }
        return try NotarizationTicket(bytes: bytes)
    }

    private func reply(_ records: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["records": records])
    }

    @Test func asksForEachCDHashByVersionAndType() throws {
        let body = try #require(
            try JSONSerialization.jsonObject(with: Verifier.ticketLookupBody([hash])) as? [String: [[String: String]]])
        #expect(body["records"] == [["recordName": "2/2/\(hash.hex)"]])
    }

    @Test func aTicketThatListsTheAppIsNotarized() throws {
        let ticket = try ticket(listing: [hash])
        let data = try reply([
            [
                "recordName": "2/2/\(hash.hex)",
                "fields": ["signedTicket": ["value": Data(ticket.bytes).base64EncodedString()]],
            ]
        ])
        #expect(Verifier.ticketAnswer(fromReply: data, cdhashes: [hash]) == .notarized(ticket))
    }

    @Test func aTicketForOtherCodeIsNotNotarized() throws {
        let other = try ticket(listing: [CDHash(hashType: 2, bytes: [UInt8](repeating: 1, count: CDHash.length))])
        let data = try reply([
            ["recordName": "x", "fields": ["signedTicket": ["value": Data(other.bytes).base64EncodedString()]]]
        ])
        #expect(Verifier.ticketAnswer(fromReply: data, cdhashes: [hash]) == .notFound)
    }

    @Test func notFoundIsAnAnswerAndGarbageIsNot() throws {
        let missing = try reply([["recordName": "2/2/\(hash.hex)", "serverErrorCode": "NOT_FOUND"]])
        #expect(Verifier.ticketAnswer(fromReply: missing, cdhashes: [hash]) == .notFound)
        #expect(Verifier.ticketAnswer(fromReply: Data("<html>portal</html>".utf8), cdhashes: [hash]) == .unreachable)
        #expect(Verifier.ticketAnswer(fromReply: try reply([]), cdhashes: [hash]) == .unreachable)
    }
}
