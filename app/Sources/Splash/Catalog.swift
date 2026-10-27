import Foundation

/// The models Splash suggests: `install/suggested-models.tsv`, which shell completion reads too.
/// Each line is `MODEL<TAB>NAME<TAB>MEMORY`: the ID `splash serve --model` takes, the model's name,
/// and the smallest Mac memory in GB the variant is meant for. Best first.
struct Catalog {
    struct Variant: Hashable {
        let id: String
        let name: String
        let memory: Int
    }

    let variants: [Variant]

    init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    init(text: String) {
        variants = text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard !line.hasPrefix("#"), fields.count == 3, let memory = Int(fields[2]) else { return nil }
            return Variant(id: fields[0], name: fields[1], memory: memory)
        }
    }

    /// For each model, best first, the variant for a Mac with `memory` GB: the one meant for the
    /// most memory that Mac has, the first listed among equals. Models it has too little memory for
    /// are left out.
    func suggestions(memory: Int) -> [Variant] {
        var chosen: [String: Variant] = [:]
        for variant in variants where variant.memory <= memory {
            if variant.memory > chosen[variant.name]?.memory ?? -1 { chosen[variant.name] = variant }
        }
        var names: [String] = []
        for variant in variants where !names.contains(variant.name) { names.append(variant.name) }
        return names.compactMap { chosen[$0] }
    }

    /// The least memory any suggested model is meant for.
    var minimumMemory: Int? { variants.map(\.memory).min() }

    /// The name to show for model `id`: its suggested name, or else its repository's.
    func name(of id: String) -> String {
        variants.first { $0.id == id }?.name
            ?? String(id.split(separator: "/").last ?? Substring(id))
    }

    /// This Mac's unified memory in GB, as Apple sells it (24, 36, 48, ...).
    static var memory: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded())
    }
}
