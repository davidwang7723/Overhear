import Foundation

/// Minimal streaming client for a local Ollama server (127.0.0.1:11434).
/// The only network traffic is to localhost — nothing leaves the machine.
final class OllamaClient {
    static let baseURL = URL(string: "http://127.0.0.1:11434")!

    struct Message: Encodable {
        let role: String
        let content: String
        /// Base64 PNG/JPEG data for vision models (M5). Nil for text.
        var images: [String]? = nil
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
        struct Options: Encodable { let temperature: Double }
    }

    private struct ChatChunk: Decodable {
        struct Msg: Decodable { let content: String }
        let message: Msg?
        let done: Bool
    }

    enum ClientError: LocalizedError {
        case unreachable
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Ollama not reachable at 127.0.0.1:11434. Is `ollama serve` running?"
            case .http(let c): return "Ollama HTTP \(c)"
            }
        }
    }

    /// True if the Ollama server answers.
    func isReachable() async -> Bool {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct ShowResponse: Decodable { let capabilities: [String]? }

    /// Model capabilities reported by Ollama (e.g. "completion", "vision",
    /// "tools"). Empty on failure.
    func capabilities(model: String) async -> [String] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let show = try? JSONDecoder().decode(ShowResponse.self, from: data)
        else { return [] }
        return show.capabilities ?? []
    }

    /// Names of locally-installed models (e.g. "qwen2.5:7b"), sorted.
    func listModels() async -> [String] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        return tags.models.map(\.name).sorted()
    }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let options: ChatRequest.Options
    }
    private struct GenerateResponse: Decodable { let response: String }

    /// One-shot, non-streaming completion. Used by the question classifier.
    func complete(model: String, prompt: String, temperature: Double = 0) async throws -> String {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try JSONEncoder().encode(
            GenerateRequest(model: model, prompt: prompt, stream: false,
                            options: .init(temperature: temperature)))
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode)
        }
        return (try JSONDecoder().decode(GenerateResponse.self, from: data)).response
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-streaming convenience: run a chat and return the full text.
    func chatComplete(model: String, messages: [Message],
                      temperature: Double = 0.2) async -> String {
        var out = ""
        do {
            for try await piece in chatStream(model: model, messages: messages,
                                              temperature: temperature) {
                out += piece
            }
        } catch {
            NSLog("Overhear chatComplete failed: \(error)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stream a chat completion. Yields incremental content deltas.
    func chatStream(model: String,
                    messages: [Message],
                    temperature: Double = 0.3) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(
                        ChatRequest(model: model, messages: messages,
                                    stream: true, options: .init(temperature: temperature)))

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw ClientError.http(http.statusCode)
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let chunk = try? decoder.decode(ChatChunk.self, from: data)
                        else { continue }
                        if let piece = chunk.message?.content, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    let mapped = (error as NSError).domain == NSURLErrorDomain
                        ? ClientError.unreachable : error
                    continuation.finish(throwing: mapped)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
