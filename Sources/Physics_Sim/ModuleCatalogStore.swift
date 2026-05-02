import Foundation

struct ModuleBundle: Identifiable, Equatable {
    let id: String
    let kind: ModuleKind
    let manifestURL: URL
    let bundleURL: URL
    let descriptor: ModuleDescriptor?
    let manifest: ModuleManifest?
}

@MainActor
final class MainWindowModuleCatalogStore: ObservableObject {
    static let shared = MainWindowModuleCatalogStore()

    @Published private(set) var availableBundles: [ModuleBundle] = []

    private let projectRootURL = MainWindowModuleCatalogStore.findProjectRoot()

    var modulesRootURL: URL {
        projectRootURL.appendingPathComponent("Modules", isDirectory: true)
    }

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        var scanned: [ModuleBundle] = []

        guard let enumerator = fm.enumerator(
            at: modulesRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            availableBundles = []
            return
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "module.json" else { continue }
            let bundleURL = url.deletingLastPathComponent()
            guard let manifest = parseManifest(at: url),
                  let kind = ModuleKind(rawValue: manifest.kind) else {
                continue
            }
            let descriptor = makeDescriptor(from: manifest)
            scanned.append(
                ModuleBundle(
                    id: manifest.id,
                    kind: kind,
                    manifestURL: url,
                    bundleURL: bundleURL,
                    descriptor: descriptor,
                    manifest: manifest
                )
            )
        }

        availableBundles = scanned.sorted {
            ($0.descriptor?.name ?? $0.bundleURL.lastPathComponent) < ($1.descriptor?.name ?? $1.bundleURL.lastPathComponent)
        }
    }

    private func parseManifest(at url: URL) -> ModuleManifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(ModuleManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    private func makeDescriptor(from manifest: ModuleManifest) -> ModuleDescriptor {
        if let known = ModuleCatalog.knownModulesByName[manifest.name] {
            return known.withPipelineMetadata(
                moduleID: manifest.id,
                version: manifest.version,
                executionModel: manifest.executionModel,
                pipelineStage: manifest.pipelineStage,
                entryPoints: manifest.entryPoints
            )
        }

        return ModuleDescriptor(
            moduleID: manifest.id,
            kind: manifest.kind,
            name: manifest.name,
            version: manifest.version,
            visibility: .production,
            isDefaultFallback: false,
            acceptsOptimizationDebugInfo: false,
            providesOptimizationDebugInfo: false,
            supportsLeaderCommunicationLog: false,
            executionModel: manifest.executionModel,
            pipelineStage: manifest.pipelineStage,
            entryPoints: manifest.entryPoints
        )
    }

    private static func findProjectRoot() -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        while true {
            let packageFile = candidate.appendingPathComponent("Package.swift").path
            let modulesDirectory = candidate.appendingPathComponent("Modules").path
            if fileManager.fileExists(atPath: packageFile),
               fileManager.fileExists(atPath: modulesDirectory) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            }
            candidate = parent
        }
    }
}
