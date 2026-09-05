import Foundation

enum HealthProbe {
    static func localHealthy() async -> Bool {
        await healthy(url: URL(string: "http://127.0.0.1:8788/healthz"))
    }

    static func publicHealthy(baseURL: String) async -> Bool {
        guard var components = URLComponents(string: baseURL) else { return false }
        components.path = "/healthz"
        components.queryItems = [URLQueryItem(name: "check", value: UUID().uuidString)]
        return await healthy(url: components.url)
    }

    private static func healthy(url: URL?) async -> Bool {
        guard let url else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 && String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        } catch {
            return false
        }
    }
}
