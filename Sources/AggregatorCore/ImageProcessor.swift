import Foundation

/// Image resize spec, per the edition format contract: opaque JPEG, quality 0.72, longest
/// edge capped at 1400px (never upscaled), named by content sha (see `SHA256.hexDigest16`).
///
/// No ImageIO/UIKit anywhere in this package (Linux requirement) -- resizing shells out:
///   - ImageMagick (`magick`, falling back to the v6 name `convert`) -- present on GitHub's
///     ubuntu runners. `-resize 1400x1400>` only ever shrinks; `-background white -alpha
///     remove -alpha off` flattens transparency to opaque white; `-strip` drops metadata.
///   - `sips` -- the Darwin fallback so the compiler runs on this Mac too. sips' `-Z` WOULD
///     upscale a smaller image, so the builder probes dimensions first and only passes `-Z`
///     when the source's longest edge exceeds the cap (JPEG re-encode alone handles the rest;
///     JPEG has no alpha channel, so output is opaque by construction).
/// vips is deliberately not wired up: ImageMagick is guaranteed on the runners and
/// vipsthumbnail's flatten/output flags vary by version -- no third variant to misbuild.
enum ImageTool: Equatable {
    case magick(path: String)
    case convert(path: String)
    case sips(path: String)
}

enum ImageProcessorError: Error, Equatable {
    case noToolAvailable
    case commandFailed(tool: String, status: Int32, stderr: String)
    case probeParseFailed(String)
    case emptyOutput
}

enum ImageProcessor {
    static let maxEdgePixels = 1400
    /// contract q0.72 -- both tools take 0-100.
    static let jpegQuality = 72

    /// Detection order: magick (IM7), convert (IM6), sips (Darwin). First hit wins.
    static func detectTool(findExecutable: (String) -> String? = { ProcessRunner.findExecutable($0) }) -> ImageTool? {
        if let path = findExecutable("magick") { return .magick(path: path) }
        if let path = findExecutable("convert") { return .convert(path: path) }
        if let path = findExecutable("sips") { return .sips(path: path) }
        return nil
    }

    // MARK: - Command builders (pure -- pinned by ImageProcessorTests)

    static func imageMagickArguments(toolPath: String, input: String, output: String) -> [String] {
        [
            toolPath, input,
            "-auto-orient",
            "-resize", "\(maxEdgePixels)x\(maxEdgePixels)>",
            "-background", "white", "-alpha", "remove", "-alpha", "off",
            "-strip",
            "-quality", "\(jpegQuality)",
            "jpeg:" + output
        ]
    }

    static func sipsProbeArguments(toolPath: String, input: String) -> [String] {
        [toolPath, "-g", "pixelWidth", "-g", "pixelHeight", input]
    }

    static func sipsResizeArguments(toolPath: String, input: String, output: String,
                                    probedLongestEdge: Int) -> [String] {
        var argv = [toolPath, "-s", "format", "jpeg", "-s", "formatOptions", "\(jpegQuality)"]
        if probedLongestEdge > maxEdgePixels {
            argv += ["-Z", "\(maxEdgePixels)"]
        }
        argv += [input, "--out", output]
        return argv
    }

    /// Parses `sips -g pixelWidth -g pixelHeight` output into the longest edge.
    static func parseSipsProbeOutput(_ output: String) throws -> Int {
        var width: Int?
        var height: Int?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pixelWidth:") {
                width = Int(trimmed.dropFirst("pixelWidth:".count).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("pixelHeight:") {
                height = Int(trimmed.dropFirst("pixelHeight:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let w = width, let h = height else {
            throw ImageProcessorError.probeParseFailed(output)
        }
        return max(w, h)
    }

    // MARK: - Execution

    static func resize(tool: ImageTool, inputPath: String, outputPath: String) throws {
        switch tool {
        case .magick(let path), .convert(let path):
            let result = try ProcessRunner.run(imageMagickArguments(toolPath: path, input: inputPath, output: outputPath))
            guard result.status == 0 else {
                throw ImageProcessorError.commandFailed(tool: path, status: result.status, stderr: result.stderrText)
            }
        case .sips(let path):
            let probe = try ProcessRunner.run(sipsProbeArguments(toolPath: path, input: inputPath))
            guard probe.status == 0 else {
                throw ImageProcessorError.commandFailed(tool: path, status: probe.status, stderr: probe.stderrText)
            }
            let longestEdge = try parseSipsProbeOutput(probe.stdoutText)
            let result = try ProcessRunner.run(sipsResizeArguments(toolPath: path, input: inputPath,
                                                                    output: outputPath, probedLongestEdge: longestEdge))
            guard result.status == 0 else {
                throw ImageProcessorError.commandFailed(tool: path, status: result.status, stderr: result.stderrText)
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
        guard let size = attributes?[.size] as? Int, size > 0 else {
            throw ImageProcessorError.emptyOutput
        }
    }
}

/// Injectable resize seam for `EditionCompiler` -- tests supply a fake; production uses
/// `ToolImageResizer` (detected once per run).
protocol ImageResizing {
    /// Writes raw downloaded bytes to a temp file, resizes into `outputURL` (JPEG per the
    /// contract). Throws when the platform tool fails.
    func resize(rawData: Data, outputURL: URL) throws
}

struct ToolImageResizer: ImageResizing {
    let tool: ImageTool

    init() throws {
        guard let detected = ImageProcessor.detectTool() else {
            throw ImageProcessorError.noToolAvailable
        }
        tool = detected
    }

    init(tool: ImageTool) {
        self.tool = tool
    }

    func resize(rawData: Data, outputURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("broadsheet-img-\(UUID().uuidString).bin")
        try rawData.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        try ImageProcessor.resize(tool: tool, inputPath: inputURL.path, outputPath: outputURL.path)
    }
}
