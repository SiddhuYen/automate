import Foundation

/// iMessage through Photon (photon.codes): texts come from Photon's own line, so it works without Messages.app,
/// Full Disk Access or a keyword. Speaks Photon's gRPC-web endpoint directly (plain HTTPS, no SDK).
///
/// Credentials are a Spectrum project's id and secret (Photon dashboard → project Settings). On Free and Pro plans
/// the number you text must be added as a user of that project, or sends fail with "Target not allowed".
public actor PhotonClient {
    public let projectId: String
    private let secret: String
    private let session: URLSession
    private var token: (value: String, host: String, expires: Date)?

    public init(projectId: String, secret: String, session: URLSession = .shared) {
        self.projectId = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public struct APIError: Error, LocalizedError, Sendable {
        public var description: String
        public var isUnauthorized = false
        public var errorDescription: String? { description }
    }

    /// One message in the chat, as it arrives on the live stream.
    public struct Incoming: Sendable, Equatable {
        public var guid: String
        public var text: String
        public var isFromMe: Bool
        /// For a swipe-reply: the guid of the message it answers.
        public var replyTo: String?
    }

    public enum Event: Sendable, Equatable {
        case heartbeat
        case message(Incoming)
    }

    // Photon's Cloudflare front rejects some default user agents.
    private static let userAgent = "Automate/0.2"
    private static let cloud = "https://spectrum.photon.codes"

    // MARK: Calls

    /// The chat with `address` (a phone number or Apple ID email); creating it is a no-op if it exists.
    public func chatGuid(for address: String) async throws -> String {
        var req = Protobuf()
        req.string(1, address)
        req.int(2, 1) // CHAT_SERVICE_TYPE_IMESSAGE
        let data = try await call("photon.imessage.v1.ChatService/CreateChat", req.data)
        guard let chat = Protobuf.fields(data).message(1), let guid = Protobuf.fields(chat).string(1), !guid.isEmpty else {
            throw APIError(description: "Photon didn't return a chat for \(address)")
        }
        return guid
    }

    /// Sends a text, as a reply to `replyTo` (a message guid) if given; returns the new message's guid
    /// (for matching swipe-replies to it).
    @discardableResult
    public func sendText(_ text: String, chatGuid: String, replyTo: String? = nil) async throws -> String? {
        let data = try await call("photon.imessage.v1.MessageService/SendTextMessage",
                                  Self.sendTextRequest(text, chatGuid: chatGuid, replyTo: replyTo))
        return Protobuf.fields(data).message(1).flatMap { Protobuf.fields($0).string(1) }
    }

    static func sendTextRequest(_ text: String, chatGuid: String, replyTo: String?) -> Data {
        var req = Protobuf()
        req.string(1, chatGuid)
        req.string(2, text)
        if let replyTo, !replyTo.isEmpty {
            var target = Protobuf()
            target.string(1, replyTo) // ReplyTarget.messageGuid
            req.message(3, target)
        }
        return req.data
    }

    /// Live events for one chat until the connection drops (then the stream finishes or throws; reconnect).
    public func events(chatGuid: String) async throws -> AsyncThrowingStream<Event, Error> {
        var body = Protobuf()
        body.string(1, chatGuid)
        // The server sends heartbeats; a long silence means the connection is dead.
        let request = try await request("photon.imessage.v1.MessageService/SubscribeMessageEvents", body.data, timeout: 180)
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response, headerStatus: nil)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var reader = GRPCWebFrames()
                    for try await byte in bytes {
                        reader.append(byte)
                        while let frame = try reader.next() {
                            if frame.isTrailer {
                                if let err = Self.trailerError(frame.payload) { throw err }
                                continuation.finish()
                                return
                            }
                            if let event = Self.event(from: frame.payload) { continuation.yield(event) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Wire

    /// Short-lived access token; Free/Pro projects share one endpoint, Business ones get their own host.
    private func credentials(refresh: Bool = false) async throws -> (token: String, host: String) {
        if !refresh, let token, Date() < token.expires { return (token.value, token.host) }
        guard !projectId.isEmpty, !secret.isEmpty else { throw APIError(description: "Add your Photon project id and secret", isUnauthorized: true) }
        var req = URLRequest(url: URL(string: "\(Self.cloud)/projects/\(projectId)/imessage/tokens")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(projectId):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status), json?["succeed"] as? Bool == true, let d = json?["data"] as? [String: Any] else {
            throw APIError(description: "Photon didn't accept the project id/secret (HTTP \(status))",
                           isUnauthorized: status == 401 || status == 403)
        }
        var host = "imessage.spectrum.photon.codes"
        var value = d["token"] as? String
        if d["type"] as? String != "shared", let (instance, t) = (d["auth"] as? [String: Any])?.first {
            host = "\(instance).imsg.photon.codes"
            value = t as? String ?? (t as? [String: Any])?["token"] as? String
        }
        guard let value, !value.isEmpty else { throw APIError(description: "Photon returned no token") }
        let ttl = max(60, ((d["expiresIn"] as? NSNumber)?.doubleValue ?? 900) - 60)
        token = (value, host, Date().addingTimeInterval(ttl))
        return (value, host)
    }

    private func request(_ path: String, _ body: Data, timeout: TimeInterval = 30, refresh: Bool = false) async throws -> URLRequest {
        let (token, host) = try await credentials(refresh: refresh)
        var req = URLRequest(url: URL(string: "https://\(host)/\(path)")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "content-type")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = GRPCWebFrames.frame(body)
        return req
    }

    private func call(_ path: String, _ body: Data, retried: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(for: request(path, body, refresh: retried))
        do {
            return try Self.unary(data, response: response)
        } catch let e as APIError where e.isUnauthorized && !retried {
            return try await call(path, body, retried: true) // the token lapsed early
        }
    }

    static func unary(_ data: Data, response: URLResponse) throws -> Data {
        let http = response as? HTTPURLResponse
        try check(response, headerStatus: http?.value(forHTTPHeaderField: "grpc-status"),
                  headerMessage: http?.value(forHTTPHeaderField: "grpc-message"))
        var reader = GRPCWebFrames()
        reader.append(contentsOf: data)
        var payload = Data()
        while let frame = try reader.next() {
            if frame.isTrailer {
                if let err = trailerError(frame.payload) { throw err }
            } else {
                payload = frame.payload
            }
        }
        return payload
    }

    private static func check(_ response: URLResponse, headerStatus: String?, headerMessage: String? = nil) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || headerStatus == "16" { throw APIError(description: "Photon: not authorized", isUnauthorized: true) }
        guard code == 200 else { throw APIError(description: "Photon: HTTP \(code)") }
        if let headerStatus, headerStatus != "0" {
            throw APIError(description: "Photon: " + (headerMessage?.removingPercentEncoding ?? "error \(headerStatus)"))
        }
    }

    static func trailerError(_ payload: Data) -> APIError? {
        let text = String(decoding: payload, as: UTF8.self)
        var status = "0", message = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "grpc-status" { status = parts[1] }
            if parts[0].lowercased() == "grpc-message" { message = parts[1].removingPercentEncoding ?? parts[1] }
        }
        guard status != "0" else { return nil }
        return APIError(description: "Photon: " + (message.isEmpty ? "error \(status)" : message), isUnauthorized: status == "16")
    }

    /// SubscribeMessageEventsResponse → a new text in the chat (edits, reads and reactions are ignored).
    static func event(from payload: Data) -> Event? {
        let top = Protobuf.fields(payload)
        if top.message(99) != nil { return .heartbeat }
        guard let changed = top.message(10).map(Protobuf.fields),
              let received = changed.message(10).map(Protobuf.fields),
              let message = received.message(1).map(Protobuf.fields) else { return nil }
        let text = message.message(2).map(Protobuf.fields)?.string(1) ?? ""
        // Strip the object-replacement character attachments leave behind.
        let clean = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let replyTo = message.string(71) ?? message.string(73) // thread originator, else reply-to
        return .message(Incoming(guid: message.string(1) ?? "", text: clean,
                                 isFromMe: changed.int(4) == 1 || message.int(21) == 1,
                                 replyTo: replyTo.flatMap { $0.isEmpty ? nil : $0 }))
    }

    /// "+1 (555) 555-0100" → "+15555550100"; 10 digits are taken as a US number. Emails pass through.
    public static func address(from handle: String) -> String {
        let h = handle.trimmingCharacters(in: .whitespaces)
        guard !h.contains("@") else { return h.lowercased() }
        let digits = h.filter(\.isNumber)
        guard !digits.isEmpty else { return h }
        return "+" + (digits.count == 10 && !h.hasPrefix("+") ? "1" + digits : digits)
    }
}

/// gRPC-web framing: 1 flag byte (0x80 = trailers), 4-byte big-endian length, payload.
struct GRPCWebFrames {
    struct Frame { var isTrailer: Bool; var payload: Data }
    private var buffer = Data()

    static func frame(_ payload: Data) -> Data {
        var out = Data([0])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        return out + payload
    }

    mutating func append(_ byte: UInt8) { buffer.append(byte) }
    mutating func append(contentsOf data: Data) { buffer.append(data) }

    mutating func next() throws -> Frame? {
        guard buffer.count >= 5 else { return nil }
        let b = Array(buffer.prefix(5))
        let length = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard length <= 16_000_000 else { throw PhotonClient.APIError(description: "Photon sent a malformed frame") }
        guard buffer.count >= 5 + length else { return nil }
        let start = buffer.startIndex
        let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
        buffer = Data(buffer[(start + 5 + length)...])
        return Frame(isTrailer: b[0] & 0x80 != 0, payload: payload)
    }
}

/// Just enough protobuf for Photon's few messages: varints and length-delimited fields.
struct Protobuf {
    private(set) var data = Data()

    mutating func string(_ field: Int, _ value: String) {
        let bytes = Data(value.utf8)
        varint(UInt64(field << 3 | 2))
        varint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func message(_ field: Int, _ value: Protobuf) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.data.count))
        data.append(value.data)
    }

    mutating func int(_ field: Int, _ value: UInt64) {
        varint(UInt64(field << 3))
        varint(value)
    }

    private mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// Top-level fields of a message. Stops quietly at anything malformed.
    struct Fields {
        var varints: [Int: UInt64] = [:]
        var bytes: [Int: Data] = [:]
        func message(_ f: Int) -> Data? { bytes[f] }
        func string(_ f: Int) -> String? { bytes[f].map { String(decoding: $0, as: UTF8.self) } }
        func int(_ f: Int) -> UInt64? { varints[f] }
    }

    static func fields(_ data: Data) -> Fields {
        var out = Fields()
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                v |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return out }
                out.varints[field] = v
            case 2:
                guard let len = readVarint(), len <= UInt64(b.count - i) else { return out }
                if out.bytes[field] == nil { out.bytes[field] = Data(b[i..<(i + Int(len))]) }
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}
