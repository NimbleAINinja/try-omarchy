import AppKit
import Darwin
import Foundation

/// One run of the VM: downloading the image a new VM needs, the launcher
/// process, QMP readiness, Mac sleep, the storage volume going away, and the
/// exit. The full app's launcher and the headless run mode (`--run-vm`) both
/// run the VM through it, so the installer trial runs the same core.
@MainActor
final class VMRunSession {
    struct LaunchContext {
        var environment: [String: String]
        let stateRoot: String?
        /// Set when the chosen storage folder could not be validated.
        let storageUnavailableReason: String?
        /// Whether the download may create the storage folder that holds it.
        let mayCreateFactoryRoot: Bool
    }

    struct Exit {
        let status: Int32
        let standardError: String
        let reachedStart: Bool
        let wasStopping: Bool
        let settingsAction: VMRunLifecycle.SettingsAction?
        let hostSleepControlFailure: String?
    }

    enum Event {
        case downloadProgress(FactoryDownloadProgress)
        case downloadFinished
        case downloadCancelled
        case launchProgress(VMProgress<VMLaunchPhase>)
        case ready(qmpSocketPath: String)
        case launchFailed(Error)
        case hostWakeFailed(Error)
        case volumeUnmounted
        case exited(Exit)
    }

    private let launcherURL: URL
    private let supervisor: QEMUGPUProcessSupervisor
    private let factoryManifest: FactoryDownloadManifest?
    private let bundlesFactoryImage: Bool
    private let bundledMetrics: BundledGuestMetrics?
    private let downloadNetworkPolicy: FactoryImageDownloader.NetworkPolicy
    private let hostSleepCoordinator = VMHostSleepCoordinator()
    private var hostPowerObserver: HostPowerNotificationObserver?
    private var volumeObserver: NSObjectProtocol?

    var onEvent: (Event) -> Void = { _ in }

    private var factoryDownloader: FactoryImageDownloader?
    private var downloadCancelled = false
    /// Where this launch's downloaded image lives, cleaned once the VM runs.
    private var launchedFactoryDirectories: [URL] = []
    private var activeStateRoot: String?
    private var pendingHostSleepControlFailure: String?
    private var forcedStopTimer: DispatchWorkItem?

    private(set) var lifecycle = VMRunLifecycle()
    private(set) var isRunning = false
    private(set) var reachedStart = false
    private(set) var qmpSocketPath: String?

    var isDownloading: Bool { factoryDownloader != nil }
    var pausedForHostSleep: Bool { hostSleepCoordinator.pausedForHostSleep }

    init(
        launcherURL: URL,
        supervisor: QEMUGPUProcessSupervisor = QEMUGPUProcessSupervisor(),
        factoryManifest: FactoryDownloadManifest?,
        bundlesFactoryImage: Bool,
        bundledMetrics: BundledGuestMetrics?,
        downloadNetworkPolicy: FactoryImageDownloader.NetworkPolicy = .any
    ) {
        self.launcherURL = launcherURL
        self.supervisor = supervisor
        self.factoryManifest = factoryManifest
        self.bundlesFactoryImage = bundlesFactoryImage
        self.bundledMetrics = bundledMetrics
        self.downloadNetworkPolicy = downloadNetworkPolicy
    }

    func observeHost() {
        observeVolumeUnmounts()
        hostPowerObserver = HostPowerNotificationObserver(
            onWillSleep: { [weak self] in self?.prepareForHostSleep() },
            onDidWake: { [weak self] in self?.beginResumeAfterHostWake() }
        )
    }

    /// Downloads the image first when a new VM needs it. `context` is read
    /// again after the download; `beforeLaunch` runs just before the launcher.
    func start(
        arguments: [String],
        context: @escaping () -> LaunchContext,
        beforeLaunch: @escaping (LaunchContext) throws -> Void = { _ in }
    ) {
        guard !isRunning, factoryDownloader == nil else { return }
        downloadCancelled = false
        hostSleepCoordinator.cancelWakeRetry()
        reachedStart = false
        pendingHostSleepControlFailure = nil
        do {
            if try beginFactoryDownloadIfNeeded(context(), then: { [weak self] image in
                self?.launch(arguments: arguments, context: context, beforeLaunch: beforeLaunch,
                             downloadedFactoryImage: image)
            }) { return }
        } catch {
            onEvent(.launchFailed(error))
            return
        }
        launch(arguments: arguments, context: context, beforeLaunch: beforeLaunch, downloadedFactoryImage: nil)
    }

    /// What was downloaded stays for the next launch to resume.
    func cancelDownload() {
        guard let factoryDownloader else { return }
        downloadCancelled = true
        factoryDownloader.cancel()
    }

    enum DownloadOutcome {
        case launch(URL)
        case cancelled
        case failed(Error)
    }

    /// A download can finish just before a cancellation reaches it; the VM
    /// must not start after someone asked it to stop.
    static func downloadOutcome(_ result: Result<URL, Error>, cancelled: Bool) -> DownloadOutcome {
        switch result {
        case .success(let image): cancelled ? .cancelled : .launch(image)
        case .failure(FactoryDownloadError.cancelled): .cancelled
        case .failure(let error): .failed(error)
        }
    }

    func requestSettingsAction(_ action: VMRunLifecycle.SettingsAction) {
        lifecycle.requestSettingsAction(action)
    }

    func cancelSettingsAction() {
        lifecycle.cancelSettingsAction()
    }

    /// Asks Linux to shut down over QMP. With `forceAfter`, the launcher is
    /// stopped if the VM is still running when it elapses.
    func powerDown(forceAfter: TimeInterval? = nil) throws {
        guard isRunning, reachedStart, let qmpSocketPath else {
            throw HelperError.io("Omarchy is not running.")
        }
        let connection = try QMPConnection(socketPath: qmpSocketPath, identifierPrefix: "shutdown")
        _ = try connection.execute("system_powerdown")
        guard let forceAfter else { return }
        forcedStopTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            fputs("omarchy-vm-helper: Omarchy did not shut down in time; stopping it\n", stderr)
            self.quit()
        }
        forcedStopTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + forceAfter, execute: timer)
    }

    /// Stops the launcher, which stops QEMU and the bridges.
    func quit() {
        hostSleepCoordinator.cancelWakeRetry()
        lifecycle.requestQuit()
        supervisor.forward(signal: SIGTERM)
    }

    func terminate(signal: Int32) {
        hostSleepCoordinator.cancelWakeRetry()
        lifecycle.requestTermination(signal: signal)
        supervisor.forward(signal: signal)
    }

    /// Called again after a failed resume, when someone chooses to retry.
    func beginResumeAfterHostWake() {
        hostSleepCoordinator.cancelWakeRetry()
        resumeAfterHostWake()
        // The guest clock stood still while the Mac slept, paused or not; the
        // time zone bridge prompts the guest to recover it now.
        HostWake.post()
    }

    private func beginFactoryDownloadIfNeeded(_ context: LaunchContext,
        then launch: @escaping (URL) -> Void) throws -> Bool {
        guard let manifest = factoryManifest else { return false }
        guard case .download(var directory) = factoryImagePreparation(context),
              let stateRoot = context.stateRoot.map({ URL(fileURLWithPath: $0, isDirectory: true) })
        else { return false }
        let localFactory = stateRoot.appendingPathComponent(VMWorkspaceTransfer.factoryCacheName, isDirectory: true)
        do {
            // A disposable VM shares the storage folder's copy. A chosen folder
            // that is missing is never recreated, so the disposable workspace
            // keeps its own download instead.
            try FactoryImageStore.prepareDirectory(directory,
                mayCreateRoot: directory == localFactory || context.mayCreateFactoryRoot)
        } catch where directory != localFactory {
            directory = localFactory
            try FactoryImageStore.prepareDirectory(directory, mayCreateRoot: true)
        }
        FactoryImageStore.removeObsoleteDownloads(in: directory, identity: manifest.identity)
        // The launcher then decompresses about half the disk beside it.
        let reserve = (bundledMetrics?.sourceDiskBytes ?? 0) + StorageSpaceRequirement.headroomBytes
        let downloader = FactoryImageDownloader(manifest: manifest, directory: directory, reserveBytes: reserve,
                                                networkPolicy: downloadNetworkPolicy)
        factoryDownloader = downloader
        fputs("[download] Preparing the Omarchy image in \(directory.path)\n", stderr)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try downloader.run { progress in
                    DispatchQueue.main.async { self?.onEvent(.downloadProgress(progress)) }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.factoryDownloader === downloader else { return }
                self.factoryDownloader = nil
                switch Self.downloadOutcome(result, cancelled: self.downloadCancelled) {
                case .launch(let image):
                    self.onEvent(.downloadFinished)
                    launch(image)
                case .cancelled:
                    self.onEvent(.downloadCancelled)
                case .failed(let error):
                    self.onEvent(.launchFailed(error))
                }
            }
        }
        return true
    }

    /// The factory a new VM disk needs, for this launch's storage folder.
    private func factoryImagePreparation(_ context: LaunchContext) -> FactoryImagePreparation {
        guard context.storageUnavailableReason == nil, let stateRoot = context.stateRoot else {
            return .ready(image: nil)
        }
        return FactoryImagePreparation.plan(
            manifest: factoryManifest,
            bundlesImage: bundlesFactoryImage,
            stateRoot: URL(fileURLWithPath: stateRoot, isDirectory: true),
            sharedFactory: context.environment[QEMUGPURuntimeEnvironment.factoryCacheKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    private func launch(
        arguments: [String],
        context makeContext: () -> LaunchContext,
        beforeLaunch: (LaunchContext) throws -> Void,
        downloadedFactoryImage: URL?
    ) {
        do {
            var context = makeContext()
            // Callers normally resolve this first; failing closed here keeps a
            // silent fallback to the default folder impossible.
            if let reason = context.storageUnavailableReason {
                throw HelperError.io(reason)
            }
            try beforeLaunch(context)
            launchedFactoryDirectories = context.stateRoot.map {
                [URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent(VMWorkspaceTransfer.factoryCacheName, isDirectory: true)]
            } ?? []
            var factoryImage = downloadedFactoryImage
            if factoryImage == nil, case .ready(let image?) = factoryImagePreparation(context) {
                factoryImage = image
            }
            if let factoryImage {
                context.environment[QEMUGPURuntimeEnvironment.factoryImageKey] = factoryImage.path
                launchedFactoryDirectories.append(factoryImage.deletingLastPathComponent())
            }
            activeStateRoot = context.stateRoot
            try supervisor.start(
                executableURL: launcherURL,
                arguments: arguments,
                environment: context.environment,
                launchEvent: { [weak self] event in
                    switch event {
                    case .virtualMachineReady(let qmpSocketPath):
                        self?.virtualMachineDidStart(qmpSocketPath: qmpSocketPath)
                    case .launchProgress(let progress):
                        self?.onEvent(.launchProgress(progress))
                    case .resetProgress:
                        break
                    }
                }
            ) { [weak self] status in
                self?.childDidExit(status: status)
            }
            isRunning = true
        } catch {
            activeStateRoot = nil
            onEvent(.launchFailed(error))
        }
    }

    private func virtualMachineDidStart(qmpSocketPath: String?) {
        guard let qmpSocketPath else {
            failHostSleepControlSetup(detail: "the launcher did not provide a valid control socket")
            return
        }
        do {
            try hostSleepCoordinator.connect(to: qmpSocketPath)
        } catch {
            failHostSleepControlSetup(detail: error.localizedDescription)
            return
        }
        reachedStart = true
        self.qmpSocketPath = qmpSocketPath
        // The launcher has decompressed the factory by now, so a downloaded
        // image is no longer needed.
        if let identity = factoryManifest?.identity {
            let directories = launchedFactoryDirectories
            DispatchQueue.global(qos: .utility).async {
                for directory in Set(directories) {
                    FactoryImageStore.removeObsoleteDownloads(in: directory, identity: identity)
                }
            }
        }
        onEvent(.ready(qmpSocketPath: qmpSocketPath))
    }

    private func failHostSleepControlSetup(detail: String) {
        fputs("omarchy-vm-helper: host sleep control is unavailable: \(detail)\n", stderr)
        pendingHostSleepControlFailure = "The virtual machine started, but safe Mac sleep could not be enabled. Please close and reopen the app. (\(detail))"
        quit()
    }

    private func childDidExit(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        forcedStopTimer?.cancel()
        forcedStopTimer = nil
        hostSleepCoordinator.cancelWakeRetry()
        hostSleepCoordinator.disconnect()
        qmpSocketPath = nil
        activeStateRoot = nil
        let exit = Exit(
            status: status,
            standardError: supervisor.recentStandardError,
            reachedStart: reachedStart,
            wasStopping: lifecycle.isStopping,
            settingsAction: lifecycle.settingsAction,
            hostSleepControlFailure: pendingHostSleepControlFailure
        )
        pendingHostSleepControlFailure = nil
        lifecycle.childExited()
        onEvent(.exited(exit))
    }

    /// A physical unplug cannot be prevented, but the VM must not keep writing
    /// into a vanished mount. A graceful eject is already refused by macOS
    /// while QEMU holds the disk open and FD 9 holds its advisory lock.
    private func observeVolumeUnmounts() {
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                else { return }
                self.handleVolumeUnmount(at: volume)
            }
        }
    }

    private func handleVolumeUnmount(at volume: URL) {
        guard isRunning, !lifecycle.isTerminating, let root = activeStateRoot else { return }
        let mountPoint = volume.standardizedFileURL.path
        let prefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        guard root == mountPoint || root.hasPrefix(prefix) else { return }
        fputs("omarchy-vm-helper: the volume holding the Omarchy VM was unmounted; stopping\n", stderr)
        quit()
        onEvent(.volumeUnmounted)
    }

    /// `willSleepNotification` observers may delay host sleep while they run.
    /// Keep this synchronous so QEMU acknowledges `stop` before macOS freezes
    /// the Hypervisor.framework process.
    private func prepareForHostSleep() {
        do {
            try hostSleepCoordinator.prepareForHostSleep(vmIsRunning: isRunning, isStopping: lifecycle.isTerminating)
        } catch {
            fputs("omarchy-vm-helper: could not pause the VM before host sleep: \(error.localizedDescription)\n", stderr)
        }
    }

    private func resumeAfterHostWake() {
        do {
            try hostSleepCoordinator.resumeAfterHostWake(vmIsRunning: isRunning, isStopping: lifecycle.isTerminating)
            hostSleepCoordinator.cancelWakeRetry()
        } catch {
            fputs("omarchy-vm-helper: could not resume the VM after host wake: \(error.localizedDescription)\n", stderr)
            guard !(error is VMHostSleepControlError),
                  hostSleepCoordinator.pausedForHostSleep,
                  isRunning,
                  !lifecycle.isTerminating
            else { return }
            guard hostSleepCoordinator.scheduleWakeRetry({ [weak self] in self?.resumeAfterHostWake() }) else {
                onEvent(.hostWakeFailed(error))
                return
            }
        }
    }
}
