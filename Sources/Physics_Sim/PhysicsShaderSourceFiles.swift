import Foundation

enum PhysicsShaderSourceFiles {
    private struct PhysicsModuleManifest: Decodable {
        let name: String
        let kind: String
        let version: Int
        let shaderSource: String?
    }

    static func defaultPhysicsSource() throws -> String {
        try loadShaderSource(named: "DefaultPhysicsModule")
    }

    static func packagedPhysicsSources() throws -> [String] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Modules/Physics", isDirectory: true)
        let fileManager = FileManager.default

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try entries
            .filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { directoryURL in
                guard let manifestURL = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).first(where: { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".module.json") }) else {
                    return nil
                }

                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PhysicsModuleManifest.self, from: manifestData)
                guard manifest.kind == "physics", let shaderSource = manifest.shaderSource else {
                    return nil
                }

                let shaderURL = directoryURL.appendingPathComponent(shaderSource)
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
