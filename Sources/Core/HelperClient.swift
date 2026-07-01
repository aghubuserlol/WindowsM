import Foundation
import ServiceManagement
import Security

/// Owns the SMJobBless installation of com.windowsm.helper and the XPC
/// connection to it. The app never runs anything as root itself, every
/// privileged operation is an async wrapper here that crosses into the helper.
///
/// Note: SMJobBless is deprecated in favor of SMAppService (macOS 13+), but it
/// remains the established mechanism for blessed helpers and matches the
/// project spec. Migration would only touch this file and the helper plists.
final class HelperClient: NSObject {

    static let shared = HelperClient()

    /// Streams helper log lines (called on the main queue).
    var onLog: ((String) -> Void)?
    /// Streams helper progress: stage identifier + 0...100 (main queue).
    var onProgress: ((String, Double) -> Void)?

    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()

    // MARK: - Installation (SMJobBless)

    /// Ensures a helper with the current protocol version is installed,
    /// blessing it (with an admin prompt) when missing or outdated.
    func ensureHelperInstalled() async throws {
        if let installed = try? await version(), installed == HelperConstants.version {
            return
        }
        try blessHelper()
        // Fresh helper, drop any stale connection.
        invalidateConnection()
        let installed = try await version()
        guard installed == HelperConstants.version else {
            throw WindowsMError.helperInstallFailed("Helper version mismatch (\(installed) != \(HelperConstants.version)).")
        }
    }

    private func blessHelper() throws {
        var authRef: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
            throw WindowsMError.helperInstallFailed("AuthorizationCreate failed (\(status)).")
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        let rightName = strdup(kSMRightBlessPrivilegedHelper)!
        defer { free(rightName) }
        var item = AuthorizationItem(name: UnsafePointer(rightName), valueLength: 0, value: nil, flags: 0)
        status = withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(authRef, &rights, nil,
                                           [.interactionAllowed, .extendRights, .preAuthorize], nil)
        }
        guard status == errAuthorizationSuccess else {
            throw WindowsMError.helperInstallFailed("Administrator authorization was not granted (\(status)).")
        }

        var blessError: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd,
                                 HelperConstants.machServiceName as CFString,
                                 authRef,
                                 &blessError)
        if !blessed {
            let reason = (blessError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
                ?? "SMJobBless returned false."
            throw WindowsMError.helperInstallFailed(reason)
        }
    }

    // MARK: - Async API over XPC

    func version() async throws -> String {
        try await call { proxy, finish in
            proxy.version { finish(.success($0)) }
        }
    }

    func partitionDiskForWindows(bsdName: String, mkntfsPath: String) async throws {
        try await callVoid { proxy, finish in
            proxy.partitionDiskForWindows(bsdName: bsdName, mkntfsPath: mkntfsPath) { finish($0) }
        }
    }

    func applyWindowsImage(wimlibPath: String, wimPath: String, imageIndex: Int, ntfsPartitionBSDName: String) async throws {
        try await callVoid { proxy, finish in
            proxy.applyWindowsImage(wimlibPath: wimlibPath,
                                    wimPath: wimPath,
                                    imageIndex: imageIndex,
                                    ntfsPartitionBSDName: ntfsPartitionBSDName) { finish($0) }
        }
    }

    func extractBootFiles(wimlibPath: String, wimPath: String, imageIndex: Int, efiMountPoint: String) async throws {
        try await callVoid { proxy, finish in
            proxy.extractBootFiles(wimlibPath: wimlibPath,
                                   wimPath: wimPath,
                                   imageIndex: imageIndex,
                                   efiMountPoint: efiMountPoint) { finish($0) }
        }
    }

    func mountPartition(bsdName: String) async throws -> String {
        try await call { proxy, finish in
            proxy.mountPartition(bsdName: bsdName) { mountPoint, error in
                if let mountPoint {
                    finish(.success(mountPoint))
                } else {
                    finish(.failure(error ?? WindowsMError.helperConnectionFailed as NSError))
                }
            }
        }
    }

    func unmount(bsdName: String) async throws {
        try await callVoid { proxy, finish in
            proxy.unmount(bsdName: bsdName) { finish($0) }
        }
    }

    func installBootchain(m1n1Path: String, edk2Path: String, bcdTemplatePath: String, driversPath: String, efiMountPoint: String) async throws {
        try await callVoid { proxy, finish in
            proxy.installBootchain(m1n1Path: m1n1Path,
                                   edk2Path: edk2Path,
                                   bcdTemplatePath: bcdTemplatePath,
                                   driversPath: driversPath,
                                   efiMountPoint: efiMountPoint) { finish($0) }
        }
    }

    func configureStartupBootOption(efiPartitionBSDName: String) async throws {
        try await callVoid { proxy, finish in
            proxy.configureStartupBootOption(efiPartitionBSDName: efiPartitionBSDName) { finish($0) }
        }
    }

    func registerStubBootObject(bsdName: String, m1n1Path: String) async throws {
        try await callVoid { proxy, finish in
            proxy.registerStubBootObject(bsdName: bsdName, m1n1Path: m1n1Path) { finish($0) }
        }
    }

    // MARK: - Plumbing

    /// Bridges one XPC round-trip into async/await. The error handler and the
    /// reply can both fire, so completion is guarded to resume exactly once.
    private func call<T>(_ body: (HelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = OnceGate()
        return try await withCheckedThrowingContinuation { continuation in
            let finish: (Result<T, Error>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            guard let proxy = remoteProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(WindowsMError.helperConnectionFailed))
                return
            }
            body(proxy, finish)
        }
    }

    private func callVoid(_ body: (HelperProtocol, @escaping (NSError?) -> Void) -> Void) async throws {
        let _: Bool = try await call { proxy, finish in
            body(proxy) { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(true))
                }
            }
        }
    }

    private func remoteProxy(errorHandler: @escaping (Error) -> Void) -> HelperProtocol? {
        currentConnection().remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? HelperProtocol
    }

    private func currentConnection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let connection {
            return connection
        }
        let newConnection = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                            options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: HelperProgressProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            self?.invalidateConnection()
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func invalidateConnection() {
        connectionLock.lock()
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        connectionLock.unlock()
    }
}

// MARK: - Progress callbacks from the helper

extension HelperClient: HelperProgressProtocol {
    func helperDidEmitLog(_ line: String) {
        DispatchQueue.main.async { self.onLog?(line) }
    }

    func helperDidUpdateProgress(stage: String, percent: Double) {
        DispatchQueue.main.async { self.onProgress?(stage, percent) }
    }
}

/// Thread-safe one-shot flag for continuation safety.
private final class OnceGate {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
