import Foundation

enum CrashReportImporter {
    private static let importedDefaultsKey = "PhysicsSim.ImportedCrashReports.v1"

    // Prototype-only: this imports reports that macOS already wrote after a crash.
    // Production crash reporting should use an app-owned crash pipeline with privacy review,
    // retention policy, symbolication, and a stable storage location.
    @MainActor
    static func importRecentReports(diagnosticsStore: MainWindowDiagnosticsStore) {
        let imported = Set(UserDefaults.standard.stringArray(forKey: importedDefaultsKey) ?? [])
        let reports = candidateReports().filter { !imported.contains(importKey(for: $0)) }
        guard !reports.isEmpty else { return }

        let destinationDirectory = IssueReportPaths.crashReportsDirectory
        var copied: [URL] = []
        var nextImported = imported

        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            for report in reports {
                let destination = uniqueDestinationURL(for: report, in: destinationDirectory)
                try FileManager.default.copyItem(at: report, to: destination)
                copied.append(destination)
                nextImported.insert(importKey(for: report))
            }
            UserDefaults.standard.set(Array(nextImported).sorted(), forKey: importedDefaultsKey)
        } catch {
            RuntimeEventLogger.log("crash_report_import_failed error=\(error.localizedDescription)")
        }

        guard !copied.isEmpty else { return }
        let folder = destinationDirectory.path
        diagnosticsStore.postNotification(
            severity: .warning,
            title: "Crash Report Imported",
            message: "\(copied.count) Particularity crash report\(copied.count == 1 ? "" : "s") copied to \(folder)."
        )
    }

    private static func candidateReports() -> [URL] {
        let fileManager = FileManager.default
        let diagnosticsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let reports = (try? fileManager.contentsOfDirectory(
            at: diagnosticsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return reports
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("Particularity") && (url.pathExtension == "ips" || url.pathExtension == "crash")
            }
            .sorted { modificationDate(for: $0) > modificationDate(for: $1) }
    }

    private static func uniqueDestinationURL(for source: URL, in directory: URL) -> URL {
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix).\(ext)", isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    private static func importKey(for url: URL) -> String {
        let date = modificationDate(for: url).timeIntervalSince1970
        return "\(url.path)|\(date)"
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
