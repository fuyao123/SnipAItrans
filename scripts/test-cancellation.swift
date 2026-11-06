import Foundation

// Concatenate TranslationService.swift and this file before compiling so the
// test can exercise the private persistent clients with disposable fake CLIs.
@main
struct CancellationChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snipai-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkGemini(in: directory)
        try await checkCodex(in: directory)
        print("Queued request cancellation checks passed")
    }

    static func prepare(_ script: String, at path: URL) throws {
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    static func waitForFile(_ path: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path.path) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fatalError("Mock process did not receive its first request")
    }

    static func checkGemini(in directory: URL) async throws {
        let log = directory.appendingPathComponent("gemini.log")
        let script = directory.appendingPathComponent("agy")
        try prepare("""
        #!/usr/bin/python3
        import json,sys,time
        print(json.dumps({'event':'init'}),flush=True)
        for line in sys.stdin:
            value=json.loads(line)['message']['content'][0]['text']
            with open('\(log.path)','a') as f: f.write(value+'\\n')
            if value=='first': time.sleep(0.6)
            print(json.dumps({'event':'result','result':{'status':'SUCCESS','response':value}}),flush=True)
        """, at: script)
        let client = AntigravityStreamClient.shared
        let first = Task { try await client.translate(prompt: "first", model: "mock", executable: script) }
        try await waitForFile(log)
        let obsolete = Task { try await client.translate(prompt: "obsolete", model: "mock", executable: script) }
        try await Task.sleep(nanoseconds: 50_000_000)
        obsolete.cancel()
        let latest = Task { try await client.translate(prompt: "latest", model: "mock", executable: script) }
        _ = try await first.value
        do { _ = try await obsolete.value; fatalError("Canceled Gemini request succeeded") } catch is CancellationError { }
        let latestValue = try await latest.value
        precondition(latestValue == "latest")
        let sent = try String(contentsOf: log, encoding: .utf8)
        precondition(!sent.contains("obsolete") && sent.contains("latest"), "A canceled Gemini request was sent")
    }

    static func checkCodex(in directory: URL) async throws {
        let log = directory.appendingPathComponent("codex.log")
        let script = directory.appendingPathComponent("codex")
        try prepare("""
        #!/usr/bin/python3
        import json,sys,time
        def send(x): print(json.dumps(x),flush=True)
        for line in sys.stdin:
            obj=json.loads(line); method=obj.get('method'); rid=obj.get('id')
            if method=='initialize': send({'id':rid,'result':{}})
            elif method=='thread/start': send({'id':rid,'result':{'thread':{'id':'test'}}})
            elif method=='turn/start':
                value=obj['params']['input'][0]['text'].split('\\n\\n')[-1]
                with open('\(log.path)','a') as f: f.write(value+'\\n')
                if value=='first': time.sleep(0.6)
                send({'id':rid,'result':{}})
                send({'method':'item/completed','params':{'item':{'type':'agentMessage','text':value}}})
                send({'method':'turn/completed','params':{}})
        """, at: script)
        let client = CodexAppServerClient.shared
        @Sendable func translate(_ text: String) async throws -> String {
            try await client.translate(text: text, source: .english, target: .chineseSimplified, model: "mock", reasoning: .low, executable: script)
        }
        let first = Task { try await translate("first") }
        try await waitForFile(log)
        let obsolete = Task { try await translate("obsolete") }
        try await Task.sleep(nanoseconds: 50_000_000)
        obsolete.cancel()
        let latest = Task { try await translate("latest") }
        _ = try await first.value
        do { _ = try await obsolete.value; fatalError("Canceled GPT request succeeded") } catch is CancellationError { }
        let latestValue = try await latest.value
        precondition(latestValue == "latest")
        let sent = try String(contentsOf: log, encoding: .utf8)
        precondition(!sent.contains("obsolete") && sent.contains("latest"), "A canceled GPT request was sent")
    }
}
