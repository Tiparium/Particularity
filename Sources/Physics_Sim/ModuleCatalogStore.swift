import Foundation

struct ModuleFile: Identifiable, Equatable {
    let id: String
    let kind: ModuleKind
    let url: URL
    let descriptor: ModuleDescriptor?
}

@MainActor
final class MainWindowModuleCatalogStore: ObservableObject {
    static let shared = MainWindowModuleCatalogStore()

    @Published private(set) var availableFiles: [ModuleFile] = []

    private let projectRootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    var modulesRootURL: URL {
        projectRootURL.appendingPathComponent("Modules", isDirectory: true)
    }

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        var scanned: [ModuleFile] = []

        for kind in ModuleKind.allCases {
            let dir = modulesRootURL.appendingPathComponent(kind.folderName, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items {
                if url.hasDirectoryPath {
                    guard let manifestURL = manifestURL(in: url) else { continue }
                    scanned.append(
                        ModuleFile(
                            id: "\(kind.rawValue)|\(manifestURL.path)",
                            kind: kind,
                            url: manifestURL,
                            descriptor: parseDescriptor(at: manifestURL)
                        )
                    )
                } else {
                    scanned.append(
                        ModuleFile(
                            id: "\(kind.rawValue)|\(url.path)",
                            kind: kind,
                            url: url,
                            descriptor: parseDescriptor(at: url)
                        )
                    )
                }
            }
        }

        availableFiles = scanned.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private func manifestURL(in directoryURL: URL) -> URL? {
        let fm = FileManager.default
        return try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: { !$0.hasDirectoryPath && $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".module.json") })
    }

    private func parseDescriptor(at url: URL) -> ModuleDescriptor? {
        struct ModuleManifest: Decodable {
            let name: String
            let kind: String
            let version: Int
        }

        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ModuleManifest.self, from: data) else {
            return nil
        }

        if let known = ModuleCatalog.knownModulesByName[manifest.name] {
            return known
        }

        return ModuleDescriptor(
            kind: manifest.kind,
            name: manifest.name,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false
        )
    }
}
