import Foundation

enum PhysicsShaderSourceFiles {
    static func defaultPhysicsSource() throws -> String {
        try loadShaderSource(named: "DefaultPhysicsModule")
    }

    static func packagedPhysicsSources() throws -> [String] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Modules", isDirectory: true)
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let manifestURLs = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.lastPathComponent == "module.json" else { return nil }
            return url
        }

        return try manifestURLs
            .sorted { $0.path < $1.path }
            .compactMap { manifestURL in
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(ModuleManifest.self, from: manifestData)
                guard manifest.kind == ModuleKind.physics.rawValue, let shaderSource = manifest.shaderSource else {
                    return nil
                }

                let shaderURL = manifestURL.deletingLastPathComponent().appendingPathComponent(shaderSource)
                do {
                    return try String(contentsOf: shaderURL, encoding: .utf8)
                } catch {
                    throw SimulationSessionError.shaderSourceLoadingFailed(
                        "Failed to read shader source for module \(manifest.name) at \(shaderURL.path). \(error.localizedDescription)"
                    )
                }
            }
    }

    private static func loadShaderSource(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal") else {
            throw SimulationSessionError.shaderSourceLoadingFailed("Missing shader resource \(name).metal.")
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SimulationSessionError.shaderSourceLoadingFailed(
                "Failed to read shader resource \(name).metal. \(error.localizedDescription)"
            )
        }
    }
}
