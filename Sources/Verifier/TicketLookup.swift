import Foundation

/// Apple's answer to "is this code notarized?", asked by cdhash before the app is staged.
public enum TicketAnswer: Sendable, Equatable {
    /// Apple's ticket service returned a ticket that lists one of the cdhashes.
    case notarized(NotarizationTicket)
    /// Apple answered, and has no ticket for any of them.
    case notFound
    /// No answer: offline, a timeout, a captive portal, or a reply this code doesn't understand.
    case unreachable
}

extension Verifier {
    /// Apple's CloudKit ticket service, the one `stapler` and Gatekeeper ask for a ticket that
    /// isn't stapled. Public and unauthenticated; records are named `2/<hash type>/<cdhash>`.
    static let ticketServiceURL = URL(
        string:
            "https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup"
    )!
    /// Record names are versioned; 2 is the only version Apple's tools use today.
    private static let ticketRecordVersion = 2
    /// A lookup reply is a few KB per record (the ticket); anything far larger isn't one.
    private static let maxTicketReply = 4 * NotarizationTicket.maxSize

    /// Asks Apple's ticket service for a notarization ticket listing any of `cdhashes`, the
    /// same lookup Gatekeeper makes at first launch for an app with no stapled ticket.
    ///
    /// Reads nothing from disk, so it can run before the app is staged: Drop's popup uses it
    /// to say "Notarized by Apple" while the copy is still being written. Only a returned
    /// ticket that lists one of the hashes counts as notarized; the ticket's own signature
    /// is checked by Gatekeeper at launch, and the full check (`assess`) still runs on the
    /// staged copy, which also catches a revoked notarization. Sends only the cdhashes.
    public static func lookUpTicket(
        for cdhashes: [CDHash], timeout: Duration, session: URLSession = .shared
    ) async -> TicketAnswer {
        // Nothing was asked, so this isn't Apple's answer: never report it as `.notFound`.
        guard !cdhashes.isEmpty else { return .unreachable }
        var request = URLRequest(url: ticketServiceURL, timeoutInterval: timeout.timeInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ticketLookupBody(cdhashes)
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return .unreachable }
        return ticketAnswer(fromReply: data, cdhashes: cdhashes)
    }

    /// The lookup's JSON body: one record per cdhash.
    static func ticketLookupBody(_ cdhashes: [CDHash]) -> Data {
        let records = cdhashes.map { ["recordName": "\(ticketRecordVersion)/\($0.hashType)/\($0.hex)"] }
        return (try? JSONSerialization.data(withJSONObject: ["records": records])) ?? Data()
    }

    /// Reads a lookup reply. Pure, so the parsing is testable without the network.
    static func ticketAnswer(fromReply data: Data, cdhashes: [CDHash]) -> TicketAnswer {
        guard data.count <= maxTicketReply,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let records = object["records"] as? [[String: Any]]
        else { return .unreachable }
        var answered = false
        for record in records {
            if let fields = record["fields"] as? [String: Any],
                let signed = fields["signedTicket"] as? [String: Any],
                let base64 = signed["value"] as? String,
                let bytes = Data(base64Encoded: base64),
                let ticket = try? NotarizationTicket(bytes: Array(bytes))
            {
                if ticket.covers(cdhashes) { return .notarized(ticket) }
                answered = true
            } else if record["serverErrorCode"] as? String == "NOT_FOUND" {
                answered = true
            }
        }
        return answered ? .notFound : .unreachable
    }
}

extension Duration {
    /// The duration in seconds, for Foundation APIs that take a `TimeInterval`.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
