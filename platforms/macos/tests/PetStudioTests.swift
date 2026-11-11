import Foundation

final class StudioMockProtocol: URLProtocol {
    static var check: ((URLRequest) -> Void)?
    static var body = ""
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.check?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct PetStudioTests {
    static func main() throws {
        let valid = #"{"actions":{"studio_jump":{"name":"跳一下","duration":1,"tracks":{"root.ty":[[0,0],[0.5,0.2],[1,0]]}}},"triggers":{"click":["studio_jump"]}}"#
        let plan = try PetStudioPlan.validate(valid)
        precondition((plan["actions"] as? [String: Any])?.count == 1)
        _ = try PetStudioPlan.validate("```json\n" + valid + "\n```")
        let invalid = [
            valid.replacingOccurrences(of: "0.2", with: "50"),
            valid.replacingOccurrences(of: "root.ty", with: "execute"),
            valid.replacingOccurrences(of: "[1,0]", with: "[0.2,0]"),
            valid.replacingOccurrences(of: "[0,0]", with: "[0,0.1]"),
            valid.replacingOccurrences(of: "[1,0]", with: "[1,0.1]"),
            valid.replacingOccurrences(of: "\"click\"", with: "\"shell\""),
            valid.replacingOccurrences(of: "[\"studio_jump\"]", with: "[\"missing\"]"),
            valid.replacingOccurrences(of: "\"duration\":1", with: "\"duration\":100"),
            valid.replacingOccurrences(of: "\"tracks\":", with: "\"command\":\"rm\",\"tracks\":")
        ]
        for bad in invalid {
            do { _ = try PetStudioPlan.validate(bad); fatalError("Invalid plan accepted: \(bad)") }
            catch { /* Expected validation failure. */ }
        }
        let settings = PetMotionSettings(json: ["intensity": Double.nan, "speed": 50, "gaze": -1])
        precondition(settings.intensity == 1 && settings.speed == 2 && settings.gaze == 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pet-studio-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let literal = "$(touch INJECTION); `echo unsafe` spaces"
        let output = try PetStudioProcess.run(executable: "/usr/bin/printf", arguments: ["%s", literal], directory: dir)
        precondition(output == literal)
        precondition(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("INJECTION").path))
        do {
            _ = try PetStudioProcess.run(executable: "/bin/sleep", arguments: ["10"], directory: dir, timeout: 0.05)
            fatalError("Timeout not enforced")
        } catch { }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StudioMockProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        for provider in ["minimax", "anthropic"] {
            var config = PetStudioConfig()
            config.provider = provider; config.model = "fixture-model"
            config.baseURL = "https://fixture.invalid/v1"
            StudioMockProtocol.check = { request in
                precondition(request.url?.path == (provider == "anthropic" ? "/v1/messages" : "/v1/chat/completions"))
                precondition(request.value(forHTTPHeaderField: provider == "anthropic" ? "x-api-key" : "Authorization") == (provider == "anthropic" ? "fixture-key" : "Bearer fixture-key"))
                precondition(request.httpMethod == "POST")
            }
            let json: [String: Any] = provider == "anthropic" ? ["content": [["type": "text", "text": valid]]]
                : ["choices": [["message": ["content": valid]]]]
            StudioMockProtocol.body = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
            let done = DispatchSemaphore(value: 0)
            PetStudioService.generate(prompt: "test motion", config: config, key: "fixture-key", directory: dir, session: session) { response in
                switch response {
                case .success(let text): precondition(text == valid)
                case .failure(let error): fatalError(error.localizedDescription)
                }
                done.signal()
            }
            precondition(done.wait(timeout: .now() + 5) == .success)
        }
        print("Pet Studio: valid plans, 9 rejection cases, motion bounds, literal arguments, timeout, MiniMax + Anthropic request/response passed")
    }
}
