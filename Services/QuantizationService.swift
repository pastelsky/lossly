import Foundation
import AppKit

// MARK: - QuantizationService

/// Runs external CLI tools (pngquant, posterizer) asynchronously via async/await.
/// All subprocess I/O is off the main thread; results are returned as Data.
actor QuantizationService {

    static let shared = QuantizationService()
    private init() {}

    // MARK: - Public API

    func quantize(
        data: Data,
        quantizer: any Quantizer,
        quality: ClosedRange<Int>,
        dither: Bool,
        speed: Int,
        posterize: Int,
        deflate: Bool = true
    ) async throws -> Data {
        let (executable, args) = quantizer.launchArguments(
            dither: dither, quality: quality, speed: speed, posterize: posterize
        )

        guard let execURL = findExecutable(named: executable) else {
            throw QuantizationError.executableNotFound(executable)
        }

        let finalArgs = buildFinalArgs(for: executable, baseArgs: args)
        var result = try await runProcess(executableURL: execURL, arguments: finalArgs, inputData: data)

        if result.isEmpty {
            throw QuantizationError.noOutput
        }

        // Post-pass: oxipng lossless DEFLATE re-optimization (if enabled).
        // oxipng reads/writes stdin→stdout with "-" argument.
        if deflate, let oxipngURL = findExecutable(named: "oxipng") {
            do {
                let oxiArgs = ["-o", "3", "--strip", "safe", "--quiet", "-"]
                let optimized = try await runProcess(executableURL: oxipngURL,
                                                    arguments: oxiArgs,
                                                    inputData: result)
                if !optimized.isEmpty && optimized.count < result.count {
                    result = optimized
                }
            } catch {
                // oxipng failure is non-fatal — keep the unoptimized result
            }
        }

        return result
    }

    // MARK: - Executable discovery

    /// Search order: app bundle MacOS dir → Resources → $PATH
    private func findExecutable(named name: String) -> URL? {
        // 1. Next to the app executable (Contents/MacOS/)
        if let bundleURL = Bundle.main.executableURL {
            let candidate = bundleURL.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // 2. App bundle Resources
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // 3. Common Homebrew / system paths
        let systemPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    // MARK: - Argument construction

    private func buildFinalArgs(for executable: String, baseArgs: [String]) -> [String] {
        switch executable {
        case "pngquant":
            // Read from stdin (-), write to stdout (--output -)
            return baseArgs + ["--output", "-", "-"]
        default:
            // posterizer reads stdin and writes stdout with no file args
            return baseArgs
        }
    }

    // MARK: - Process runner

    private func runProcess(executableURL: URL, arguments: [String], inputData: Data) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdinPipe  = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.standardInput  = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            // Accumulate stdout chunks as they arrive — critical for large images.
            // The pipe buffer is only 64 KB; if we don't drain it concurrently the
            // process will block writing stdout and never terminate.
            // Use a class wrapper so the closure captures a reference, satisfying Swift 6.
            final class Buffer: @unchecked Sendable {
                let lock = NSLock()
                var data = Data()
                func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
                func drain() -> Data { lock.withLock { data } }
            }
            let buffer = Buffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
            }

            process.terminationHandler = { proc in
                // Stop the handler and drain any final bytes
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                let tail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                buffer.append(tail)
                let outputData = buffer.drain()

                let status = proc.terminationStatus
                if status == 0 || status == 98 {
                    continuation.resume(returning: outputData)
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "exit \(status)"
                    continuation.resume(throwing: QuantizationError.processFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Write stdin on a background thread so we don't block the actor
            Thread.detachNewThread {
                stdinPipe.fileHandleForWriting.write(inputData)
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }
    }
}

// MARK: - Errors

enum QuantizationError: LocalizedError {
    case executableNotFound(String)
    case noOutput
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "\(name) not found. Install it via 'brew install \(name)' or place it in the app bundle."
        case .noOutput:
            return "Quantizer produced no output."
        case .processFailed(let msg):
            return msg.isEmpty ? "Quantization failed." : msg
        }
    }
}
