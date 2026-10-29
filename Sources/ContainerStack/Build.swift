import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import ContainerCommands
import ContainerImagesServiceClient
import ContainerizationOCI
import Foundation
import NIO

/// Image builds from a Dockerfile, driving the same BuildKit shim the CLI uses:
/// dial the `buildkit` container over vsock (starting it if needed), stream the
/// build, export an OCI tar, then load + unpack + tag it into the image store.
enum BuildService {

    /// The host architecture ("arm64" | "amd64") — the build sheet's default.
    static var defaultArch: String { Arch.hostArchitecture().rawValue }

    /// `linux/<arch>` — the only OS the platform builds for.
    static func linuxPlatform(arch: String) -> ContainerizationOCI.Platform {
        ContainerizationOCI.Platform(arch: arch, os: "linux")
    }

    /// Parse an `os/arch[/variant]` build platform; nil unless it's a valid
    /// linux platform (the only OS the builder targets).
    static func platform(_ spec: String) -> ContainerizationOCI.Platform? {
        guard let platform = try? ContainerizationOCI.Platform(from: spec), platform.os == "linux" else { return nil }
        return platform
    }

    struct Request {
        var contextDir: String
        var dockerfilePath: String        // usually <contextDir>/Dockerfile
        var dockerfileContents: Data? = nil  // inline Dockerfile; dockerfilePath is then unread
        var tag: String                   // e.g. "myapp:latest"
        var additionalTags: [String] = [] // further names for the same image (repeated -t)
        var buildArgs: [String] = []      // KEY=value
        var labels: [String] = []
        var noCache: Bool = false
        var pull: Bool = false            // re-pull base images
        var target: String = ""           // multi-stage target
        /// One entry builds a single-platform image; several build a
        /// multi-platform index (every variant is unpacked into the store).
        var platforms: [ContainerizationOCI.Platform] = [linuxPlatform(arch: defaultArch)]
    }

    /// Upstream bug apple/container#735: builds with Dockerfiles ≥16 KiB hang.
    static let maxDockerfileSize = 16 * 1024

    /// Builds `request`. `progress` gets Davit's own coarse steps. BuildKit's
    /// output (RUN output, layer progress, base-image pulls) goes straight to
    /// the process's stderr — unless `log` is set: then it is captured for
    /// the build and handed over line by line instead (see StderrTap).
    static func build(
        _ request: Request,
        log: (@Sendable (String) -> Void)? = nil,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        do {
            guard let log else { return try await run(request, progress: progress) }
            // fd 2 is process-wide: one captured build at a time.
            await captureGate.lock()
            let tap = StderrTap(onLine: log)
            do {
                try tap.start()
            } catch {
                await captureGate.unlock()
                throw error
            }
            do {
                let image = try await run(request, progress: progress)
                tap.stop()
                await captureGate.unlock()
                return image
            } catch {
                tap.stop()
                await captureGate.unlock()
                throw error
            }
        } catch let e as CLIError {
            throw e
        } catch is CancellationError {
            throw CLIError(command: "build \(request.tag)", message: "build cancelled")
        } catch {
            throw CLIError.wrap("build \(request.tag)", error)
        }
    }

    private static let captureGate = AsyncMutex()

    private static func run(
        _ request: Request,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let dockerfile: Data
        if let inline = request.dockerfileContents {
            dockerfile = inline
        } else {
            guard FileManager.default.isReadableFile(atPath: request.dockerfilePath) else {
                throw CLIError(command: "build \(request.tag)", message: "Dockerfile not found: \(request.dockerfilePath)")
            }
            dockerfile = try Data(contentsOf: URL(fileURLWithPath: request.dockerfilePath))
        }
        guard dockerfile.count < maxDockerfileSize else {
            throw CLIError(
                command: "build \(request.tag)",
                message: "Dockerfile is \(dockerfile.count) bytes; the builder currently rejects files over 16 KiB (apple/container#735)")
        }
        let dockerignore = try? Data(contentsOf: URL(fileURLWithPath: request.dockerfilePath + ".dockerignore"))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.contextDir, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError(command: "build \(request.tag)", message: "context directory not found: \(request.contextDir)")
        }
        // The platform's file sync breaks on /tmp contexts (symlink standardization
        // makes COPY fail with a cryptic "not found"); fail clearly instead.
        let resolvedContext = URL(fileURLWithPath: request.contextDir).resolvingSymlinksInPath().path
        if resolvedContext.hasPrefix("/private/tmp/") || resolvedContext.hasPrefix("/tmp/") {
            throw CLIError(
                command: "build \(request.tag)",
                message: "build contexts under /tmp aren't supported by the platform's file sync — move the context to another location (e.g. your home directory)")
        }

        let imageNames = try ([request.tag] + request.additionalTags).map { tag in
            let reference = try Reference.parse(tag)
            reference.normalize()
            return reference.description
        }
        let imageName = imageNames[0]

        await progress("Connecting to builder…")
        let systemConfig = try await Backend.systemConfig()
        let builder = try await connectBuilder(systemConfig: systemConfig, progress: progress)

        // Export destination inside the builder resource dir (mounted in the shim).
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let exportDir = health.appRoot
            .appendingPathComponent(Application.BuilderCommand.builderResourceDir)
            .appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }
        var export = try Builder.BuildExport(from: "type=oci")
        export.destination = exportDir.appendingPathComponent("out.tar")

        await progress("Building \(imageName)…")
        let config = Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: request.buildArgs,
            secrets: [:],
            // SSH agent forwarding needs the builder VM to be *created* with
            // ssh forwarding on (BuilderStart.start(ssh:), which is internal);
            // the public builder-start we use can't do it, so leave it off.
            ssh: "",
            contextDir: request.contextDir,
            dockerfile: dockerfile,
            dockerignore: dockerignore,
            labels: request.labels,
            noCache: request.noCache,
            platforms: request.platforms,
            terminal: nil,
            tags: imageNames,
            target: request.target,
            // Never true: in quiet mode BuildStdio drops the shim's stdio
            // packets without acking them, and the build hangs (1.3.1).
            // Callers that want silence redirect stderr instead.
            quiet: false,
            exports: [export],
            cacheIn: [],
            cacheOut: [],
            pull: request.pull,
            containerSystemConfig: systemConfig
        )
        try await builder.build(config)

        await progress("Loading built image…")
        guard let dest = export.destination else {
            throw CLIError(command: "build \(request.tag)", message: "missing export destination")
        }
        let result = try await ClientImage.load(from: dest.path, force: false)
        guard result.rejectedMembers.isEmpty else {
            throw CLIError(command: "build \(request.tag)", message: "built archive contains invalid members")
        }
        for image in result.images {
            try await image.unpack(platform: nil, progressUpdate: { _ in })
            for name in imageNames {
                _ = try await image.tag(new: name)
            }
        }
        return imageName
    }

    /// Dial the buildkit shim; if it isn't running, start it via the platform's
    /// own builder-start command and retry until the gRPC endpoint answers.
    private static func connectBuilder(
        systemConfig: ContainerSystemConfig,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> Builder {
        let client = ContainerClient()
        let deadline = ContinuousClock.now + .seconds(300)
        var startedBuilder = false
        while true {
            do {
                let fh = try await client.dial(id: "buildkit", port: 8088)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try await Builder(socket: fh, group: group, logger: Backend.log)
                _ = try await builder.info()
                return builder
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw CLIError(command: "build", message: "timed out waiting for the builder to start")
                }
                if !startedBuilder {
                    await progress("Starting builder… (pulls the BuildKit image on first use)")
                    let start = try Application.BuilderStart.parse([])
                    try await start.run()
                    startedBuilder = true
                }
                try await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// A FIFO async lock: `lock()` suspends until every earlier holder unlocked.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard locked else { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}

/// Redirects fd 2 into a pipe between `start()` and `stop()` and reports what
/// arrives as lines. The builder library writes BuildKit's output to stderr
/// with no other hook, so this is the only way to show a build's log.
/// Everything the process writes to stderr meanwhile is captured too.
/// A carriage return (a progress bar redrawing itself) replaces the line so
/// far, so a bar shows up once, at its final state. ANSI colors are kept.
final class StderrTap: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private var savedStderr: Int32 = -1
    private var writeEnd: Int32 = -1
    private let drained = DispatchSemaphore(value: 0)

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func start() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw CLIError(command: "build", message: "couldn't capture the build log: \(String(cString: strerror(errno)))")
        }
        let readEnd = fds[0]
        writeEnd = fds[1]
        savedStderr = dup(STDERR_FILENO)
        dup2(writeEnd, STDERR_FILENO)
        let onLine = onLine
        let drained = drained
        Thread.detachNewThread {
            var pending = Data()
            func emit(_ raw: Data) {
                var line = String(decoding: raw, as: UTF8.self)
                if let cr = line.lastIndex(of: "\r") { line = String(line[line.index(after: cr)...]) }
                onLine(line)
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(readEnd, &buffer, buffer.count)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { break }
                pending.append(contentsOf: buffer[0..<n])
                while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    emit(pending[pending.startIndex..<nl])
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            if !pending.isEmpty { emit(pending) }
            close(readEnd)
            drained.signal()
        }
    }

    /// Restores fd 2 and returns once every captured line was reported.
    func stop() {
        guard savedStderr >= 0 else { return }
        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)
        savedStderr = -1
        close(writeEnd)  // last write end: the reader sees EOF
        drained.wait()
    }
}
