import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class GIFMediaEncoder {
    private let outputURL: URL
    private let framesPerSecond: Int
    private let spool: AnonymousExportSpool
    private let sink: ImageIODataConsumerSink
    private var consumer: CGDataConsumer?
    private var destination: CGImageDestination?
    private var nextFrameIndex = 0
    private var canvasSize: (width: Int, height: Int)?
    private var isFinalized = false

    init(url: URL, frameCount: Int, framesPerSecond: Int, loopsForever: Bool) throws {
        _ = frameCount
        outputURL = url
        self.framesPerSecond = min(100, max(1, framesPerSecond))
        spool = try AnonymousExportSpool()
        sink = ImageIODataConsumerSink(spool: spool)

        let retainedSink = Unmanaged.passRetained(sink).toOpaque()
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { info, buffer, count in
                guard let info else { return 0 }
                return Unmanaged<ImageIODataConsumerSink>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .write(buffer, count: count)
            },
            releaseConsumer: { info in
                guard let info else { return }
                Unmanaged<ImageIODataConsumerSink>.fromOpaque(info).release()
            }
        )
        guard let consumer = CGDataConsumer(info: retainedSink, cbks: &callbacks) else {
            Unmanaged<ImageIODataConsumerSink>.fromOpaque(retainedSink).release()
            throw MediaExportError.destinationCreationFailed
        }
        self.consumer = consumer

        // Zero keeps ImageIO on the incremental path used by open-ended recordings.
        // Apple does not document zero as an unknown count, so regression tests cover it.
        guard let destination = CGImageDestinationCreateWithDataConsumer(
            consumer,
            UTType.gif.identifier as CFString,
            0,
            nil
        ) else {
            throw MediaExportError.destinationCreationFailed
        }
        self.destination = destination
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopsForever ? 0 : 1,
            ],
        ] as CFDictionary)
    }

    func add(_ image: CGImage) throws {
        guard !isFinalized, let destination else {
            throw MediaExportError.destinationFinalizeFailed
        }
        guard image.width > 0,
              image.height > 0,
              image.width <= Int(UInt16.max),
              image.height <= Int(UInt16.max) else {
            throw MediaExportError.unsupportedGIFDimensions
        }
        if let canvasSize {
            guard canvasSize.width == image.width, canvasSize.height == image.height else {
                throw MediaExportError.inconsistentFrameDimensions
            }
        } else {
            canvasSize = (image.width, image.height)
        }

        let startCentiseconds = Int(
            (Double(nextFrameIndex) * 100.0 / Double(framesPerSecond)).rounded()
        )
        let endCentiseconds = Int(
            (Double(nextFrameIndex + 1) * 100.0 / Double(framesPerSecond)).rounded()
        )
        let delay = Double(max(1, endCentiseconds - startCentiseconds)) / 100.0
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        CGImageDestinationAddImage(destination, image, frameProperties)
        guard !sink.hasWriteFailed else { throw MediaExportError.destinationWriteFailed }
        nextFrameIndex += 1
    }

    func finalize() throws {
        guard !isFinalized, nextFrameIndex > 0, let destination else {
            throw MediaExportError.destinationFinalizeFailed
        }
        guard !sink.hasWriteFailed else { throw MediaExportError.destinationWriteFailed }
        guard CGImageDestinationFinalize(destination) else {
            if sink.hasWriteFailed { throw MediaExportError.destinationWriteFailed }
            throw MediaExportError.destinationFinalizeFailed
        }
        guard !sink.hasWriteFailed else { throw MediaExportError.destinationWriteFailed }

        self.destination = nil
        consumer = nil
        try spool.materialize(at: outputURL)
        isFinalized = true
    }
}

private final class ImageIODataConsumerSink {
    private let spool: AnonymousExportSpool
    private let lock = NSLock()
    private var writeFailed = false

    init(spool: AnonymousExportSpool) {
        self.spool = spool
    }

    var hasWriteFailed: Bool {
        lock.withLock { writeFailed }
    }

    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        lock.withLock {
            guard !writeFailed else { return 0 }
            let written = spool.write(buffer, count: count)
            if written != count {
                writeFailed = true
            }
            return written
        }
    }
}

private final class AnonymousExportSpool {
    private var fileDescriptor: Int32

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Particularity-GIF-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw MediaExportError.destinationCreationFailed }
        fileDescriptor = descriptor
        guard unlink(template) == 0 else {
            close(descriptor)
            fileDescriptor = -1
            throw MediaExportError.destinationCreationFailed
        }
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard fileDescriptor >= 0 else { return 0 }
        var totalWritten = 0
        while totalWritten < count {
            let result = Darwin.write(
                fileDescriptor,
                buffer.advanced(by: totalWritten),
                count - totalWritten
            )
            if result > 0 {
                totalWritten += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                return totalWritten
            }
        }
        return totalWritten
    }

    func materialize(at destinationURL: URL) throws {
        guard fileDescriptor >= 0,
              fsync(fileDescriptor) == 0,
              lseek(fileDescriptor, 0, SEEK_SET) >= 0 else {
            throw MediaExportError.destinationWriteFailed
        }

        let destinationDescriptor = open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else { throw MediaExportError.destinationWriteFailed }
        var succeeded = false
        defer {
            close(destinationDescriptor)
            if !succeeded {
                unlink(destinationURL.path)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw MediaExportError.destinationWriteFailed
            }

            var offset = 0
            while offset < bytesRead {
                let bytesWritten = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: offset),
                        bytesRead - offset
                    )
                }
                if bytesWritten > 0 {
                    offset += bytesWritten
                } else if bytesWritten < 0, errno == EINTR {
                    continue
                } else {
                    throw MediaExportError.destinationWriteFailed
                }
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw MediaExportError.destinationWriteFailed
        }
        succeeded = true
    }
}
