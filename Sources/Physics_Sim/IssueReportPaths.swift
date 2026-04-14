import Foundation

enum IssueReportPaths {
    // Prototype-only: repo-relative while issue reporting is still a lab feature.
    // Before publishing, move this behind an app-owned support directory or user-selected export path.
    private static let projectRoot = findProjectRoot()

    static let crashReportsDirectory = projectRoot
        .appendingPathComponent("Sources/lab/data/issue_reports/crash_reports", isDirectory: true)

    static let validationReportsDirectory = projectRoot
        .appendingPathComponent("Sources/lab/data/issue_reports/validation_reports", isDirectory: true)

    private static func findProjectRoot() -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        while true {
            let packageFile = candidate.appendingPathComponent("Package.swift").path
            let sourceDirectory = candidate.appendingPathComponent("Sources/Physics_Sim").path
            if fileManager.fileExists(atPath: packageFile),
               fileManager.fileExists(atPath: sourceDirectory) {
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
