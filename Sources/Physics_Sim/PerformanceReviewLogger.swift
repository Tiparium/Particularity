import Combine
import Foundation

private struct PendingPerformanceReviewSample {
    let deadline: Date
    let trigger: String
}

private struct BufferedPerformanceReviewEntry {
    let fileName: String
    let timestamp: String
    let encodedLine: Data
}

private struct PerformanceReviewFileHeader {
    let startedAt: String
    let physicsModule: String
    let visualModule: String
    let optimizationModule: String
}

private struct PerformanceReviewSettingsPayload: Equatable {
    let particleCount: Int
    let randomDistribution: Bool
    let particleTypes: Int
    let allParticlesIntercommunicate: Bool
    let movementDirectionX: Double
    let movementDirectionY: Double
    let movementDirectionZ: Double
    let timeScale: Double
    let sphereSize: Double
    let spectrumOffset: Double
    let showOptimizationInfo: Bool
    let showLeaderCommunicationLog: Bool
    let protectLeaderFromUnload: Bool
}

private struct PerformanceReviewMetricsPayload {
    let projectedBytes: UInt64
    let memoryUsedBytes: UInt64
    let averageFPS: Double
    let averageUPS: Double
    let leaderInteractionsPerSecond: Double
}

private struct PerformanceReviewLogEntry {
    let type: String
    let timestamp: String
    let trigger: String?
    let settings: PerformanceReviewSettingsPayload?
    let metrics: PerformanceReviewMetricsPayload?

    func renderedData() -> Data {
        var lines = ["type: \(type)"]
        if let trigger {
            lines.append("  trigger: \(trigger)")
        }
        if let settings {
            lines.append("  settings: \(settings.renderedSummary)")
        }
        if let metrics {
            lines.append("  metrics: \(metrics.renderedSummary)")
        }
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func settingsBlock(
        type: String,
        timestamp: String,
        trigger: String,
        settings: PerformanceReviewSettingsPayload
    ) -> PerformanceReviewLogEntry {
        PerformanceReviewLogEntry(
            type: type,
            timestamp: timestamp,
            trigger: trigger,
            settings: settings,
            metrics: nil
        )
    }

    static func sample(
        type: String,
        timestamp: String,
        trigger: String,
        metrics: PerformanceReviewMetricsPayload
    ) -> PerformanceReviewLogEntry {
        PerformanceReviewLogEntry(
            type: type,
            timestamp: timestamp,
            trigger: trigger,
            settings: nil,
            metrics: metrics
        )
    }
}

private extension PerformanceReviewSettingsPayload {
    var renderedSummary: String {
        "particles=\(particleCount) " +
        "random=\(randomDistribution) " +
        "types=\(particleTypes) " +
        "intercommunicate=\(allParticlesIntercommunicate) " +
        "direction=(\(Self.format(movementDirectionX)),\(Self.format(movementDirectionY)),\(Self.format(movementDirectionZ))) " +
        "timeScale=\(Self.format(timeScale)) " +
        "sphereSize=\(Self.format(sphereSize)) " +
        "spectrumOffset=\(Self.format(spectrumOffset)) " +
        "optimizationInfo=\(showOptimizationInfo) " +
        "leaderLog=\(showLeaderCommunicationLog) " +
        "protectLeader=\(protectLeaderFromUnload)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension PerformanceReviewMetricsPayload {
    var renderedSummary: String {
        "fps=\(Self.format(averageFPS)) " +
        "ups=\(Self.format(averageUPS)) " +
        "leaderIPS=\(Self.format(leaderInteractionsPerSecond)) " +
        "memoryUsed=\(memoryUsedBytes) " +
        "projected=\(projectedBytes)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct PerformanceReviewSample: Codable {
    let physicsModule: String
    let visualModule: String
    let optimizationModule: String
    let transportState: String
    let particleCount: Int
    let randomDistribution: Bool
    let particleTypes: Int
    let allParticlesIntercommunicate: Bool
    let movementDirectionX: Double
    let movementDirectionY: Double
    let movementDirectionZ: Double
    let timeScale: Double
    let sphereSize: Double
    let spectrumOffset: Double
    let showOptimizationInfo: Bool
    let showLeaderCommunicationLog: Bool
    let protectLeaderFromUnload: Bool
    let projectedBytes: UInt64
    let memoryUsedBytes: UInt64
    let averageFPS: Double
    let averageUPS: Double
    let leaderInteractionsPerSecond: Double

    fileprivate var settingsPayload: PerformanceReviewSettingsPayload {
        PerformanceReviewSettingsPayload(
            particleCount: particleCount,
            randomDistribution: randomDistribution,
            particleTypes: particleTypes,
            allParticlesIntercommunicate: allParticlesIntercommunicate,
            movementDirectionX: movementDirectionX,
            movementDirectionY: movementDirectionY,
            movementDirectionZ: movementDirectionZ,
            timeScale: timeScale,
            sphereSize: sphereSize,
            spectrumOffset: spectrumOffset,
            showOptimizationInfo: showOptimizationInfo,
            showLeaderCommunicationLog: showLeaderCommunicationLog,
            protectLeaderFromUnload: protectLeaderFromUnload
        )
    }

    fileprivate var metricsPayload: PerformanceReviewMetricsPayload {
        PerformanceReviewMetricsPayload(
            projectedBytes: projectedBytes,
            memoryUsedBytes: memoryUsedBytes,
            averageFPS: averageFPS,
            averageUPS: averageUPS,
            leaderInteractionsPerSecond: leaderInteractionsPerSecond
        )
    }

    var comboFileName: String {
        let rawName = "\(physicsModule)__\(visualModule)__\(optimizationModule)"
        let sanitized = rawName
            .lowercased()
            .map { character -> Character in
                switch character {
                case "a"..."z", "0"..."9", "-", "_":
                    return character
                default:
                    return "_"
                }
            }
        return String(sanitized) + ".log"
    }
}

@MainActor
final class PerformanceReviewLogger: ObservableObject {
    static let shared = PerformanceReviewLogger()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var bufferedSampleCount: Int = 0
    @Published private(set) var currentComboFileName: String?
    @Published private(set) var currentBudgetOccupancyBytes: Int = 0

    private let tickInterval: TimeInterval = 1
    private let steadyStateSampleInterval: TimeInterval = 60
    private let burstOffsets: [TimeInterval] = [0, 1, 2, 4, 8, 16, 32]
    private let settingsChurnTimeout: TimeInterval = 5
    private let settingsChurnSampleInterval: TimeInterval = 5
    private let maxBufferedBytes = 8 * 1024 * 1024
    private let maxTotalBytes = 20 * 1024 * 1024
    private let formatter = ISO8601DateFormatter()
    private var snapshotProvider: (() -> PerformanceReviewSample?)?
    private var timer: DispatchSourceTimer?
    private var cancellables: Set<AnyCancellable> = []
    private var bufferedEntries: [BufferedPerformanceReviewEntry] = []
    private var bufferedBytes: Int = 0
    private var configuredCoordinatorID: ObjectIdentifier?
    private var pendingSamples: [PendingPerformanceReviewSample] = []
    private var nextSteadyStateSampleAt: Date?
    private var persistedBytesEstimate: Int = 0
    private var lastSettingsByFileName: [String: PerformanceReviewSettingsPayload] = [:]
    private var headersByFileName: [String: PerformanceReviewFileHeader] = [:]
    private var startedFiles: Set<String> = []
    private var lastObservedSettings: PerformanceReviewSettingsPayload?
    private var settingsChurnDeadline: Date?
    private var lastSettingsChurnSampleAt: Date?

    init() {
        isEnabled = ProgramSettingsStore.performanceReviewLoggingEnabled
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func configure(
        runtimeConfigCoordinator: SimulationRuntimeConfigCoordinator,
        snapshotProvider: @escaping () -> PerformanceReviewSample?
    ) {
        self.snapshotProvider = snapshotProvider
        lastObservedSettings = snapshotProvider()?.settingsPayload

        let coordinatorID = ObjectIdentifier(runtimeConfigCoordinator)
        if configuredCoordinatorID != coordinatorID {
            configuredCoordinatorID = coordinatorID
            cancellables.removeAll()

            runtimeConfigCoordinator.$transportState
                .removeDuplicates()
                .sink { [weak self] transportState in
                    guard let self else { return }
                    switch transportState {
                    case .running:
                        self.captureSample(trigger: "transport_running")
                        self.scheduleBurstSamples(triggerPrefix: "transport_running")
                        self.nextSteadyStateSampleAt = Date().addingTimeInterval(self.steadyStateSampleInterval)
                    case .paused, .stopped:
                        self.finalizeSettingsChurn(scheduleBurst: false)
                        self.captureSample(trigger: "transport_\(transportState.rawValue)")
                        self.pendingSamples.removeAll(keepingCapacity: false)
                        self.nextSteadyStateSampleAt = nil
                    }
                }
                .store(in: &cancellables)

            runtimeConfigCoordinator.$simulationState
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.registerSettingsChangeIfNeeded()
                }
                .store(in: &cancellables)

            runtimeConfigCoordinator.$activeModules
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.registerSettingsChangeIfNeeded()
                }
                .store(in: &cancellables)
        }

        refreshPersistedBudgetUsage()
        updateBudgetOccupancy()
        startTimerIfNeeded()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        ProgramSettingsStore.performanceReviewLoggingEnabled = enabled
        if !enabled {
            pendingSamples.removeAll(keepingCapacity: false)
            nextSteadyStateSampleAt = nil
            settingsChurnDeadline = nil
            lastSettingsChurnSampleAt = nil
        } else if nextSteadyStateSampleAt == nil {
            nextSteadyStateSampleAt = Date().addingTimeInterval(steadyStateSampleInterval)
            scheduleBurstSamples(triggerPrefix: "logging_enabled")
        }
        updateBudgetOccupancy()
    }

    func flushBufferedSamples() {
        timer?.cancel()
        timer = nil

        guard !bufferedEntries.isEmpty else { return }

        do {
            let fileManager = FileManager.default
            let directory = Self.outputDirectoryURL
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let bufferedEntriesByFileName = Dictionary(grouping: bufferedEntries, by: \.fileName)
            for (fileName, bufferedEntries) in bufferedEntriesByFileName {
                let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
                let existingBody = existingLogBody(at: fileURL)
                let prependedBody = bufferedEntries.reduce(into: "") { partial, entry in
                    partial += String(decoding: entry.encodedLine, as: UTF8.self)
                }
                let header = headerText(for: fileName, fallbackTimestamp: bufferedEntries.first?.timestamp ?? formatter.string(from: Date()))
                let combinedData = Data((header + prependedBody + existingBody).utf8)
                try combinedData.write(to: fileURL, options: Data.WritingOptions.atomic)
            }

            trimPersistedLogsIfNeeded(in: directory)
        } catch {
            RuntimeEventLogger.log("performance_review flush_failed error=\(error.localizedDescription)")
        }

        bufferedEntries.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        bufferedSampleCount = 0
        currentComboFileName = nil
        lastSettingsByFileName.removeAll(keepingCapacity: false)
        headersByFileName.removeAll(keepingCapacity: false)
        startedFiles.removeAll(keepingCapacity: false)
        refreshPersistedBudgetUsage()
        updateBudgetOccupancy()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler { [weak self] in
            self?.processScheduledSamples()
        }
        self.timer = timer
        timer.resume()
    }

    private func processScheduledSamples() {
        guard isEnabled else { return }
        let now = Date()

        if let settingsChurnDeadline {
            if lastSettingsChurnSampleAt == nil
                || now.timeIntervalSince(lastSettingsChurnSampleAt ?? now) >= settingsChurnSampleInterval {
                captureSample(trigger: "settings_churn_sparse")
                lastSettingsChurnSampleAt = now
            }

            if now >= settingsChurnDeadline {
                finalizeSettingsChurn(scheduleBurst: true)
            } else {
                return
            }
        }

        if let nextSteadyStateSampleAt, now >= nextSteadyStateSampleAt {
            captureSample(trigger: "steady_state")
            self.nextSteadyStateSampleAt = now.addingTimeInterval(steadyStateSampleInterval)
        }

        let ready = pendingSamples.filter { $0.deadline <= now }
        pendingSamples.removeAll { $0.deadline <= now }
        for pendingSample in ready {
            captureSample(trigger: pendingSample.trigger)
        }
    }

    private func scheduleBurstSamples(triggerPrefix: String) {
        guard isEnabled else { return }
        let now = Date()
        pendingSamples.append(contentsOf: burstOffsets.map { offset in
            PendingPerformanceReviewSample(
                deadline: now.addingTimeInterval(offset),
                trigger: "\(triggerPrefix)_+\(Int(offset))s"
            )
        })
        pendingSamples.sort { $0.deadline < $1.deadline }
    }

    private func registerSettingsChangeIfNeeded() {
        guard isEnabled else { return }
        guard let snapshotProvider, let sample = snapshotProvider() else { return }

        let settings = sample.settingsPayload
        let now = Date()

        guard settings != lastObservedSettings else { return }
        lastObservedSettings = settings

        pendingSamples.removeAll(keepingCapacity: false)

        if settingsChurnDeadline == nil {
            appendSettingsEntry(trigger: "settings_churn_start", sample: sample, at: now)
            lastSettingsChurnSampleAt = nil
        }

        settingsChurnDeadline = now.addingTimeInterval(settingsChurnTimeout)
        captureSparseSettingsChurnSampleIfNeeded(now: now)
    }

    private func captureSparseSettingsChurnSampleIfNeeded(now: Date) {
        guard lastSettingsChurnSampleAt == nil
            || now.timeIntervalSince(lastSettingsChurnSampleAt ?? now) >= settingsChurnSampleInterval
        else {
            return
        }

        captureSample(trigger: "settings_churn_sparse")
        lastSettingsChurnSampleAt = now
    }

    private func finalizeSettingsChurn(scheduleBurst: Bool) {
        guard settingsChurnDeadline != nil else { return }
        let now = Date()

        if let snapshotProvider, let sample = snapshotProvider() {
            appendSettingsEntry(trigger: "settings_churn_end", sample: sample, at: now)
            currentComboFileName = sample.comboFileName
        }

        self.settingsChurnDeadline = nil
        lastSettingsChurnSampleAt = nil

        if scheduleBurst {
            scheduleBurstSamples(triggerPrefix: "settings_churn_end")
            nextSteadyStateSampleAt = now.addingTimeInterval(steadyStateSampleInterval)
        }
    }

    private func appendSettingsEntry(trigger: String, sample: PerformanceReviewSample, at date: Date) {
        let entry = PerformanceReviewLogEntry.settingsBlock(
            type: trigger,
            timestamp: formatter.string(from: date),
            trigger: trigger,
            settings: sample.settingsPayload
        )
        ensureHeader(for: sample, timestamp: entry.timestamp)
        appendLogEntry(entry, fileName: sample.comboFileName)
        lastSettingsByFileName[sample.comboFileName] = sample.settingsPayload
    }

    private func appendLogEntry(_ entry: PerformanceReviewLogEntry, fileName: String) {
        let encodedLine = entry.renderedData()
        bufferedEntries.append(
            BufferedPerformanceReviewEntry(
                fileName: fileName,
                timestamp: entry.timestamp,
                encodedLine: encodedLine
            )
        )
        bufferedBytes += encodedLine.count
        trimBufferedEntriesIfNeeded()
        bufferedSampleCount = bufferedEntries.count
        currentComboFileName = fileName
        updateBudgetOccupancy()
    }

    private func captureSample(trigger: String) {
        guard isEnabled else { return }
        guard let snapshotProvider, let sample = snapshotProvider() else { return }
        guard sample.transportState == SimulationTransportState.running.rawValue || trigger.hasPrefix("transport_") || trigger == "logging_enabled_+0s" else { return }
        let timestamp = formatter.string(from: Date())
        ensureHeader(for: sample, timestamp: timestamp)

        let entryType = sampleType(for: trigger, fileName: sample.comboFileName)
        let sampleEntry = PerformanceReviewLogEntry.sample(
            type: entryType,
            timestamp: timestamp,
            trigger: trigger,
            metrics: sample.metricsPayload
        )
        appendLogEntry(sampleEntry, fileName: sample.comboFileName)
        if entryType == "start" {
            startedFiles.insert(sample.comboFileName)
        }
    }

    private func trimBufferedEntriesIfNeeded() {
        guard bufferedBytes > maxBufferedBytes else { return }
        while bufferedBytes > maxBufferedBytes, !bufferedEntries.isEmpty {
            bufferedBytes -= bufferedEntries.removeFirst().encodedLine.count
        }
    }

    private func refreshPersistedBudgetUsage() {
        let directory = Self.outputDirectoryURL
        let fileManager = FileManager.default
        let existingFiles = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        persistedBytesEstimate = existingFiles.reduce(0) { partial, fileURL in
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + fileSize
        }
    }

    private func updateBudgetOccupancy() {
        currentBudgetOccupancyBytes = persistedBytesEstimate + bufferedBytes
    }

    private func ensureHeader(for sample: PerformanceReviewSample, timestamp: String) {
        guard headersByFileName[sample.comboFileName] == nil else { return }
        headersByFileName[sample.comboFileName] = PerformanceReviewFileHeader(
            startedAt: timestamp,
            physicsModule: sample.physicsModule,
            visualModule: sample.visualModule,
            optimizationModule: sample.optimizationModule
        )
    }

    private func sampleType(for trigger: String, fileName: String) -> String {
        if trigger == "settings_churn_sparse" {
            return "churn_sample"
        }
        if trigger.hasPrefix("transport_paused") || trigger.hasPrefix("transport_stopped") {
            return "stop"
        }
        if trigger.hasPrefix("transport_running") || !startedFiles.contains(fileName) {
            return "start"
        }
        return "sample"
    }

    private func headerText(for fileName: String, fallbackTimestamp: String) -> String {
        let header = headersByFileName[fileName] ?? PerformanceReviewFileHeader(
            startedAt: fallbackTimestamp,
            physicsModule: "unknown",
            visualModule: "unknown",
            optimizationModule: "unknown"
        )
        return """
        performance_review_log: v2
        started_at: \(header.startedAt)
        modules: physics=\(header.physicsModule) visual=\(header.visualModule) optimization=\(header.optimizationModule)
        ---

        """
    }

    private func existingLogBody(at fileURL: URL) -> String {
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        guard let separatorRange = existing.range(of: "---\n\n") else { return "" }
        return String(existing[separatorRange.upperBound...])
    }

    private func trimPersistedLogsIfNeeded(in directory: URL) {
        let fileManager = FileManager.default
        guard var files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var totalBytes = files.reduce(0) { partial, fileURL in
            partial + ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        while totalBytes > maxTotalBytes, !files.isEmpty {
            files.sort {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
                return lhs < rhs
            }

            let oldestFile = files.removeFirst()
            let oldSize = (try? oldestFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            if oldestFile.pathExtension != "log" {
                try? fileManager.removeItem(at: oldestFile)
                totalBytes -= oldSize
                continue
            }

            guard let existing = try? String(contentsOf: oldestFile, encoding: .utf8),
                  let separatorRange = existing.range(of: "---\n\n")
            else {
                try? fileManager.removeItem(at: oldestFile)
                totalBytes -= oldSize
                continue
            }

            let header = String(existing[..<separatorRange.upperBound])
            let body = String(existing[separatorRange.upperBound...])
            var blocks = body
                .components(separatedBy: "\n\ntype: ")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            guard !blocks.isEmpty else {
                try? fileManager.removeItem(at: oldestFile)
                totalBytes -= oldSize
                continue
            }

            blocks.removeFirst()
            if blocks.isEmpty {
                try? fileManager.removeItem(at: oldestFile)
                totalBytes -= oldSize
                continue
            }

            let rebuiltBody = blocks.enumerated().map { index, block in
                index == 0 ? "type: \(block)" : "\n\ntype: \(block)"
            }.joined()
            let rebuilt = header + rebuiltBody + "\n"
            let rebuiltData = Data(rebuilt.utf8)
            try? rebuiltData.write(to: oldestFile, options: .atomic)
            totalBytes = totalBytes - oldSize + rebuiltData.count
            files.append(oldestFile)
        }
    }

    var maxBudgetBytes: Int {
        maxTotalBytes
    }

    var budgetUsageFraction: Double {
        guard maxTotalBytes > 0 else { return 0 }
        return Double(currentBudgetOccupancyBytes) / Double(maxTotalBytes)
    }

    var isNearBudgetLimit: Bool {
        budgetUsageFraction >= 0.8
    }

    private static var outputDirectoryURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".home", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("performance_reviews", isDirectory: true)
    }
}
