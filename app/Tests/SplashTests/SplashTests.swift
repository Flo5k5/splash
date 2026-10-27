import Foundation
import Testing

@testable import Splash

struct CatalogTests {
    let catalog = Catalog(text: """
        # MODEL\tNAME\tMEMORY
        a/Big-GGUF:Q4\tBig\t36
        a/Big-MLX\tBig\t36
        a/Big-GGUF:Q2\tBig\t24
        a/Huge-GGUF:Q4\tHuge\t128
        a/Small-GGUF:Q2\tSmall\t24
        not a line
        a/Bad\tBad\tlots
        """)

    @Test func parsesDataLinesOnly() {
        #expect(catalog.variants.map(\.id) == ["a/Big-GGUF:Q4", "a/Big-MLX", "a/Big-GGUF:Q2", "a/Huge-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.minimumMemory == 24)
    }

    @Test func suggestsTheLargestVariantTheMacHasMemoryFor() {
        #expect(catalog.suggestions(memory: 36).map(\.id) == ["a/Big-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 24).map(\.id) == ["a/Big-GGUF:Q2", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 128).map(\.id) == ["a/Big-GGUF:Q4", "a/Huge-GGUF:Q4", "a/Small-GGUF:Q2"])
        #expect(catalog.suggestions(memory: 16).isEmpty)
    }

    @Test func namesModels() {
        #expect(catalog.name(of: "a/Big-MLX") == "Big")
        #expect(catalog.name(of: "someone/Other-GGUF:Q8_0") == "Other-GGUF:Q8_0")
    }
}

struct ServeSettingsTests {
    @Test func defaultsServeOfflineOnThePort() {
        #expect(ServeSettings().serveArguments(model: "a/b:Q4")
            == ["serve", "--model", "a/b:Q4", "--port", "8000", "--offline"])
    }

    @Test func passesChangedSettingsAndOptions() {
        let settings = ServeSettings(port: 8100, idleRelease: .never, options: " --max-context 128K\t--kv-format bf16 ")
        #expect(settings.serveArguments(model: "a/b")
            == ["serve", "--model", "a/b", "--port", "8100", "--offline", "--idle-release", "off",
                "--max-context", "128K", "--kv-format", "bf16"])
        #expect(settings.url.absoluteString == "http://127.0.0.1:8100")
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

    @Test func readsDownloadEvents() {
        let progress = Installer.Progress(
            line: #"{"event": "download", "repo": "a/b", "done": 250, "total": 1000}"#)
        #expect(progress?.repo == "a/b")
        #expect(progress?.fraction == 0.25)
        #expect(Installer.Progress(line: #"{"event": "other", "repo": "a/b", "done": 1, "total": 2}"#) == nil)
        #expect(Installer.Progress(line: "Fetching 1 file(s), 0.93 GB") == nil)
    }

    @Test func formatsContext() {
        #expect(Format.tokens(262_144) == "256K")
        #expect(Format.tokens(53_241) == "53,241")
    }
}
