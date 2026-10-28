import Foundation

/// Calls the Sottovoce server's OpenAI-compatible endpoint /v1/audio/transcriptions.
enum Transcriber {
    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// With model "preview" the server uses the fast preview model (for live preview); by default the main model
    /// produces the final text
    static func transcribe(wav: Data, server: String, token: String, model: String? = nil,
                           timeout: TimeInterval = 30) async throws -> String {
        guard let url = URL(string: server.trimmingSuffix("/") + "/v1/audio/transcriptions") else {
            throw ServiceError(message: String(localized: "Invalid server address"))
        }
        let boundary = "Sottovoce-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("response_format", "text")
        if let model { field("model", model) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&req, token)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        } catch {
            throw ServiceError(message: String(localized: "Can't reach the transcription service"))
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw ServiceError(message: String(localized: "Invalid token")) }
        guard code == 200 else {
            throw ServiceError(message: String(localized: "Transcription service returned \(code)"))
        }
        return String(decoding: data, as: UTF8.self)
    }

    enum Status: Equatable {
        case ok, unauthorized, unreachable
    }

    /// Service status for the settings window. /health needs no token, so request /v1/models to validate the token too
    static func check(server: String, token: String) async -> Status {
        guard let url = URL(string: server.trimmingSuffix("/") + "/v1/models") else { return .unreachable }
        var req = URLRequest(url: url, timeoutInterval: 3)
        authorize(&req, token)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return .unreachable }
        switch (resp as? HTTPURLResponse)?.statusCode {
        case 200: return .ok
        case 401: return .unauthorized
        default: return .unreachable
        }
    }

    private static func authorize(_ req: inout URLRequest, _ token: String) {
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
