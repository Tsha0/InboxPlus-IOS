import Foundation
import InboxPlusRuntime

extension RuntimeExitCode {
    /// Maps every typed runtime error the CLI can surface onto one documented, stable code.
    public init(for error: any Error) {
        switch error {
        case is RuntimeCommandError:
            self = .usage
        case is RuntimePathError:
            self = .unsafePath
        case let error as RuntimeStateError:
            self = RuntimeExitCode(for: error)
        case let error as ManagedProcessError:
            self = RuntimeExitCode(for: error)
        case is SynapseSupervisorError, is HealthFailure, is HealthCheckerError:
            self = .healthFailure
        case is RuntimeBootstrapError, is RuntimeManifestError, is ProfileLockError:
            self = .unavailableDependency
        case let error as RuntimeProfileError:
            self = RuntimeExitCode(for: error)
        case let error as RemovalError:
            self = RuntimeExitCode(for: error)
        case let error as BackupError:
            self = RuntimeExitCode(for: error)
        case is SynapseConfigurationError, is ProbeCredentialStoreError, is RuntimeProfileStoreError:
            self = .integrityFailure
        default:
            self = .benchmarkFailure
        }
    }

    private init(for error: RuntimeStateError) {
        switch error {
        case .invalidTransition:
            self = .invalidTransition
        case .invalidSnapshot:
            self = .integrityFailure
        case .processExitedUnexpectedly:
            self = .healthFailure
        case .processIdentityMismatch, .uncontrolledProcess:
            self = .processIdentityMismatch
        case .shutdownIncomplete:
            self = .shutdownIncomplete
        }
    }

    private init(for error: RuntimeProfileError) {
        switch error {
        case .profileNotPrepared, .missingRuntimeManifest:
            self = .unprepared
        case .pythonExecutableUnavailable, .keyGenerationFailed:
            self = .unavailableDependency
        case .runtimeOwnedByForegroundSession, .profileLockedByAnotherSession:
            self = .invalidTransition
        case .portAllocationFailed:
            self = .processLaunchFailed
        }
    }

    private init(for error: RemovalError) {
        switch error {
        case .confirmationMismatch:
            self = .usage
        case .runtimeMustBeStopped:
            self = .invalidTransition
        case .unsafeSymlink, .exportDestinationInsideProfile:
            self = .unsafePath
        case .residueRemains:
            self = .integrityFailure
        }
    }

    private init(for error: BackupError) {
        switch error {
        case .runtimeMustBeStopped:
            self = .invalidTransition
        case .invalidBackupName:
            self = .usage
        case .targetNotEmpty, .missingSourceFile, .cannotWrite:
            self = .unsafePath
        case .checksumMismatch, .backupNotFound:
            self = .integrityFailure
        }
    }

    private init(for error: ManagedProcessError) {
        switch error {
        case .launchIdentityUnavailable, .processIdentityUnavailable, .processNotOwned:
            self = .processIdentityMismatch
        default:
            self = .processLaunchFailed
        }
    }
}
