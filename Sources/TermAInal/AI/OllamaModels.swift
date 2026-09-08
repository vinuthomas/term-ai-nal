import Foundation

/// Lists the models installed in a local Ollama.
///
/// Port of the `get-ollama-models` IPC handler in `main.ts`, which the Electron
/// settings screen used to turn the model field into a populated dropdown.
enum OllamaModels {
    static func list(baseUrl: String) async -> [String] {
        let trimmed = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "http://localhost:11434" : trimmed
        guard let url = URL(string: base + "/api/tags") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map(\.name).sorted()
        } catch {
            // Ollama simply not running is the common case, not an error worth
            // surfacing — the UI shows an empty list and a hint.
            return []
        }
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}
