import Foundation
import Testing

@testable import Splash

struct CatalogTests {
    let catalog = Catalog(text: """
        # MODEL\tNAME\tMEMORY\tSIZE\tABOUT
        a/Big-GGUF:Q4\tBig\t36\t22\tFast
        a/Big-MLX\tBig\t36\t21\tFast
        a/Big-GGUF:Q2\tBig\t24\t14\tFast
        a/Huge-GGUF:Q4\tHuge\t128\t82\tLargest
        a/Small-GGUF:Q2\tSmall\t24\t12\tSmallest download
        not a line
        a/Bad\tBad\tlots\t1\tNo
        """)

    @Test func parsesDataLinesOnly() {
        #expect(catalog.variants.map(\.id) == ["a/Big-GGUF:Q4", "a/Big-MLX", "a/Big-GGUF:Q2", "a/Huge-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.minimumMemory == 24)
        #expect(catalog.variants[0].size == 22)
        #expect(catalog.about(of: "a/Small-GGUF:Q2") == "Smallest download")
        #expect(catalog.about(of: "someone/else") == nil)
    }

    @Test func suggestsTheLargestVariantTheMacHasMemoryFor() {
        #expect(catalog.suggestions(memory: 36).map(\.id) == ["a/Big-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 24).map(\.id) == ["a/Big-GGUF:Q2", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 128).map(\.id) == ["a/Big-GGUF:Q4", "a/Huge-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 16).isEmpty)
    }

    @Test func namesModels() {
        #expect(catalog.name(of: "a/Big-MLX") == "Big")
        #expect(catalog.name(of: "someone/Other-GGUF:Q8_0") == "Other")
        #expect(catalog.name(of: "someone/Other-4bit") == "Other-4bit")
        #expect(Catalog.variant(of: "someone/Other-GGUF:Q8_0") == "Q8_0")
        #expect(Catalog.variant(of: "mlx-community/Other-4bit") == "MLX")
        #expect(Catalog.variant(of: "someone/Other-4bit") == "Other-4bit")
    }
}

struct ServeSettingsTests {
    @Test func defaultsServeOfflineOnThePort() {
        #expect(ServeSettings().serveArguments(model: "a/b:Q4")
            == ["serve", "--model", "a/b:Q4", "--port", "8000", "--offline"])
    }

    @Test func passesTheOptionsSetInTheTablesOrder() {
        let settings = ServeSettings(values: [
            "--port": "8100", "--max-context": "131072", "--max-memory": "48G", "--idle-release": "off",
            "--language-only": "true", "--kv-format": "bf16", "--max-cache-disk": "16G", "--persistent-cache": "true",
            "--host": "0.0.0.0", "--allowed-origin": "a.example, b.example", "--no-webui": "true",
            "--thinking-end-text": "Now the answer. </think>", "--disable-ane": "true",
        ], apiKey: "secret")
        #expect(settings.serveArguments(model: "a/b")
            == ["serve", "--model", "a/b", "--port", "8100", "--offline", "--max-context", "131072",
                "--max-memory", "48G", "--idle-release", "off", "--language-only", "--kv-format", "bf16",
                "--max-cache-disk", "16G", "--persistent-cache", "--host", "0.0.0.0",
                "--allowed-origin", "a.example", "--allowed-origin", "b.example", "--no-webui",
                "--thinking-end-text", "Now the answer. </think>", "--disable-ane"])
        // The key reaches the server in its environment, never its command line.
        #expect(settings.environment == ["SPLASH_API_KEY": "secret"])
        #expect(settings.request("status").value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(settings.url.absoluteString == "http://127.0.0.1:8100")
        #expect(settings.memoryLimit == 48)
    }

    @Test func leavesOutOptionsTheOthersLeaveNoEffect() {
        // An SSD cache that is off keeps nothing, writes nothing and has no folder; the first other
        // name needs one.
        let off = ServeSettings(values: ["--max-cache-disk": "0", "--persistent-cache": "true", "--cache-dir": "/tmp/c",
                                         "--max-cache-disk-writes": "100G", "--announce-served-name": "true"])
        #expect(off.serveArguments(model: "a/b") == ServeSettings(values: ["--max-cache-disk": "0"]).serveArguments(model: "a/b"))
        #expect(!off.differs(from: ServeSettings(values: ["--max-cache-disk": "0"]), model: "a/b"))
        #expect(ServeSettings(apiKey: "new").differs(from: ServeSettings(), model: "a/b"))
    }

    @Test func readsAndNamesContextLengths() {
        #expect(ContextLength.parse("100K") == 102_400)
        #expect(ContextLength.parse(" 1m ") == 1_000_000)
        #expect(ContextLength.parse("65536") == 65536)
        #expect(ContextLength.parse("0") == nil && ContextLength.parse("12.5K") == nil && ContextLength.parse("lots") == nil)
        #expect(ContextLength.title(32768) == "32K tokens")
        #expect(ContextLength.title(1_000_000) == "1M tokens")
        #expect(ContextLength.title(100_000) == "100,000 tokens")
    }

    @Test func offersMemoryLimitsBelowTheMacs() {
        #expect(ServeSettings.memoryLimits(memory: 36) == [8, 12, 16, 24, 32])
    }

    @Test func saysWhatMakesRoomForAModel() {
        let floors = "runtime bootstrap failed [resource_assembly/memory_planning]: model weights with the runtime reserves, one lane's state, the KV runway and any SSD cache state staging require 10858659840 bytes but the Metal memory budget is 1073741824 bytes"
        #expect(Server.memoryProblem(floors, settings: ServeSettings(values: ["--max-memory": "1G"]))
            == "It needs 10.1 GB of memory but the memory limit is 1 GB. Raise the memory limit in Launch Options.")
        #expect(Server.memoryProblem(floors, settings: ServeSettings())
            == "It needs 10.1 GB of memory but this Mac can give it 1 GB. Choose a smaller model.")
        let context = { (bound: String) in
            "runtime bootstrap failed [model_creation]: --max-context 262144 exceeds the 73721 tokens the model and \(bound) allow; omit it or pass at most 73721"
        }
        #expect(Server.memoryProblem(context("this Mac's memory"), settings: ServeSettings(values: ["--max-context": "262144"]))
            == "Its context fits up to 71K tokens on this Mac. Choose a shorter context length, or Auto.")
        #expect(Server.memoryProblem(context("--max-memory"), settings: ServeSettings(values: ["--max-context": "262144"]))
            == "Its context fits up to 71K tokens within the memory limit. Choose a shorter context length, or raise the memory limit.")
        #expect(Server.memoryProblem(context("the SSD cache's room for its KV"), settings: ServeSettings(values: ["--max-context": "262144"]))
            == "Its context fits up to 71K tokens in the SSD cache. Choose a shorter context length, or a larger SSD cache.")
        #expect(Server.memoryProblem("error: something else", settings: ServeSettings()) == nil)
    }

    @Test func keepsTheOptionsAndReadsBadOnesAsDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "splash-tests-\(UUID().uuidString)"))
        #expect(ServeSettings.current(defaults).values.isEmpty)
        let settings = ServeSettings(values: ["--port": "9000", "--max-context": "32768", "--max-memory": "20G",
                                              "--allowed-host": "mymac.local", "--allow-idle-sleep": "true"],
                                     apiKey: Keychain.apiKey)
        settings.save(defaults)
        #expect(ServeSettings.current(defaults) == settings)
        defaults.set(["--port": "70000", "--max-context": "-1", "--max-memory": "lots", "--nope": "1",
                      "--kv-format": "bf16"], forKey: Preference.launchOptions)
        #expect(ServeSettings.current(defaults).values == ["--kv-format": "bf16"])
    }

    @Test func typedValuesTakeServesForms() throws {
        func custom(_ flag: String) throws -> LaunchOption.Value {
            let option = try #require(LaunchOption.all.first { $0.flag == flag })
            switch option.kind {
            case .choice(_, _, let custom?): return custom
            case .text(let custom, _): return custom
            default: throw CancellationError()
            }
        }
        #expect(try custom("--max-context").parse("100K") == "102400")
        #expect(try custom("--max-memory").parse("40") == "40G")
        #expect(try custom("--expert-memory").parse("2.5 g") == "2.5G")
        #expect(try custom("--expert-memory").parse("lots") == nil)
        #expect(try custom("--idle-release").parse("45M") == "45m")
        #expect(try custom("--port").parse("0") == nil)
        #expect(try custom("--served-model-name").parse("gpt-4o,  o3 ") == "gpt-4o, o3")
    }
}

struct OutputTests {
    @Test func findsErrorLines() {
        #expect(errorMessage("error: model download or verification failed") == "model download or verification failed")
        #expect(errorMessage("12:01:02 Error · unable to start HTTP server: [Errno 48]")
            == "unable to start HTTP server: [Errno 48]")
        #expect(errorMessage("12:01:02 Loading · a/b") == nil)
        #expect(errorMessage("Warning: something") == nil)
    }

    @Test func saysWhyFilesCannotServe() {
        #expect(plainProblem("cannot prepare /m/d: no supported model has this architecture (X)", model: "/m/d")
            == "Splash can’t serve these files: no supported model has this architecture (X)")
    }

    @Test func readsDownloadEvents() {
        let progress = Installer.Progress(
            line: #"{"event": "download", "repo": "a/b", "done": 250, "total": 1000}"#)
        #expect(progress?.repo == "a/b")
        #expect(progress?.fraction == 0.25)
        #expect(Installer.Progress(line: #"{"event": "other", "repo": "a/b", "done": 1, "total": 2}"#) == nil)
        #expect(Installer.Progress(line: "Fetching 1 file(s), 0.93 GB") == nil)
    }

    @Test func formatsSizes() {
        #expect(Format.size(120_000_000) == "120 MB")
        #expect(Format.size(6_730_000_000) == "6.7 GB")
        #expect(Format.size(10_980_000_000) == "11 GB")
        #expect(Format.size(21_250_000_000) == "21 GB")
        #expect(Format.size(Format.gigabytes(24)) == "24 GB")
    }
}

struct ChatTests {
    @Test func readsTheEventStream() throws {
        #expect(try ChatClient.parse(": splash-keepalive") == nil)
        #expect(try ChatClient.parse("data: [DONE]") == .done)
        let delta = try ChatClient.parse(#"data: {"choices":[{"delta":{"reasoning_content":"hm","content":"Hi"}}],"metrics":{"request_latency":{"stream_tokens_per_second":71.5}}}"#)
        #expect(delta == .delta(ChatClient.Delta(text: "Hi", reasoning: "hm", tokensPerSecond: 71.5)))
        #expect(try ChatClient.parse(#"data: {"choices":[]}"#) == .delta(ChatClient.Delta()))
        #expect(try ChatClient.parse(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
            == .delta(ChatClient.Delta(cut: true)))
        #expect(throws: ChatClient.Failure.self) {
            try ChatClient.parse(#"data: {"error":{"message":"engine is recovering; retry shortly"}}"#)
        }
    }

    @Test func asksWithImagesEarlierThoughtsAndTheEffort() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1])
        let messages = [ChatMessage(role: .user, text: "What is this?", images: [png]),
                        ChatMessage(role: .assistant, text: "A cat.", reasoning: "Whiskers."),
                        ChatMessage(role: .user, text: "Sure?"),
                        ChatMessage(role: .assistant, text: "", error: "The reply was interrupted."),
                        ChatMessage(role: .user, text: "Well?")]
        let body = try JSONSerialization.jsonObject(with: ChatClient.body(messages, effort: "low", images: true)) as! [String: Any]
        #expect(body["reasoning_effort"] as? String == "low")
        #expect(body["stream"] as? Bool == true)
        let wire = body["messages"] as! [[String: Any]]
        let parts = wire[0]["content"] as! [[String: Any]]
        #expect((parts[0]["image_url"] as! [String: String])["url"] == "data:image/png;base64,\(png.base64EncodedString())")
        #expect(parts[1]["text"] as? String == "What is this?")
        #expect(wire[1]["reasoning_content"] as? String == "Whiskers.")
        // The interrupted answer, which holds nothing, is left out.
        #expect(wire.map { $0["role"] as? String } == ["user", "assistant", "user", "user"])
        let auto = try JSONSerialization.jsonObject(with: ChatClient.body(messages, effort: "", images: true)) as! [String: Any]
        #expect(auto["reasoning_effort"] == nil)
        // A model that cannot see images gets a note in their place.
        let text = try JSONSerialization.jsonObject(with: ChatClient.body(messages, effort: "", images: false)) as! [String: Any]
        #expect((text["messages"] as! [[String: Any]])[0]["content"] as? String == "[An image this model can’t see]\n\nWhat is this?")
    }

    @MainActor @Test func keepsConversationsInTheirFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "splash-chat-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ChatStore(folder: folder)
        #expect(store.conversations.isEmpty)
        // Sending to no server fails, and the conversation keeps the question and why.
        let nowhere = ChatTarget(url: URL(string: "http://127.0.0.1:9")!, model: "a/b", acceptsImages: false, effort: "")
        store.send("Hello\nthere", images: [], to: nowhere)
        #expect(store.current?.title == "Hello")
        #expect(store.streaming != nil)
        while store.streaming != nil { try await Task.sleep(for: .milliseconds(20)) }
        let answer = try #require(store.current?.messages.last)
        #expect(answer.role == .assistant && answer.model == "a/b" && answer.error != nil)
        store.rename(store.conversations[0].id, to: "Greeting")
        let reloaded = ChatStore(folder: folder)
        #expect(reloaded.conversations.map(\.title) == ["Greeting"])
        #expect(reloaded.conversations[0].messages == store.conversations[0].messages)
        store.delete(store.conversations[0].id)
        #expect(store.conversations.isEmpty && store.selection == nil)
        #expect(ChatStore(folder: folder).conversations.isEmpty)
    }

    @MainActor @Test func anAnswerTheAppQuitDuringSaysSo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "splash-chat-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let conversation = Conversation(title: "Hi", messages: [ChatMessage(role: .user, text: "Hi"),
                                                               ChatMessage(role: .assistant, text: "")])
        try JSONEncoder().encode(conversation).write(to: folder.appending(path: "\(conversation.id.uuidString).json"))
        #expect(ChatStore(folder: folder).conversations[0].messages[1].error == "The reply was interrupted.")
    }
}
