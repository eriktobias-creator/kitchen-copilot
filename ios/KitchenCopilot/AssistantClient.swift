import Foundation

struct Turn: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
}

private struct AskBody: Encodable {
    var question: String
    var history: [Turn]
    var rush: Bool
    var localTime: String
    var imageJpegBase64: String?
}

private struct ServerEvent: Decodable {
    var type: String
    var text: String?
    var message: String?
}

enum AssistantEvent {
    case delta(String)
    case done
}

/// Talks to the Kitchen Copilot server (never to Claude directly, so the API
/// key never lives on the phone).
struct AssistantClient {
    var baseURL: URL
    var token: String

    func ask(question: String, history: [Turn], rush: Bool, imageJpeg: Data? = nil)
        -> AsyncThrowingStream<AssistantEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "ask"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONEncoder().encode(AskBody(
                        question: question,
                        history: history,
                        rush: rush,
                        localTime: Self.localTime(),
                        imageJpegBase64: imageJpeg?.base64EncodedString()
                    ))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.server("No response") }
                    if http.statusCode == 401 { throw ClientError.server("App token doesn't match the server.") }
                    guard http.statusCode == 200 else { throw ClientError.server("Server error \(http.statusCode).") }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let event = try JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8))
                        switch event.type {
                        case "delta": continuation.yield(.delta(event.text ?? ""))
                        case "done": continuation.yield(.done)
                        case "error": throw ClientError.server(event.message ?? "Server error.")
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    static func localTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE h:mm a"
        return f.string(from: Date())
    }
}

enum ClientError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let m): m }
    }
}
