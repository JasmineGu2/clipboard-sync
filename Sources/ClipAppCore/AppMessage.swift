import ClipCrypto
import ClipStore
import ClipSync
import Foundation

/// Errors from setting up the app itself (not from the sync layers).
public enum AppError: Error, Equatable, Sendable {
    case invalidServerURL
    /// No config or no vault key yet: onboarding hasn't finished.
    case notSetUp
    /// The platform key store (Keychain) failed.
    case keyStore(String)
}

/// A user-visible message. The UI shows `text`; the raw error never reaches the screen.
public enum AppMessage: String, Equatable, Sendable, CaseIterable {
    case emptyText
    case tooLarge
    case invalidCode
    case codeNotFound
    case codeMismatch
    case invalidServer
    case serverUnreachable
    case server
    case unauthorized
    case rateLimited
    case storage
    case keychain
    case notSetUp
    case fileTooLarge
    case unreadableFile
    case notUploadedYet
    case downloadFailed
    case unknown

    /// The copy for this message, from `Strings`.
    public var text: String {
        switch self {
        case .emptyText: Strings.errorEmptyText
        case .tooLarge: Strings.errorTooLarge
        case .invalidCode: Strings.errorInvalidCode
        case .codeNotFound: Strings.errorCodeNotFound
        case .codeMismatch: Strings.errorCodeMismatch
        case .invalidServer: Strings.errorInvalidServer
        case .serverUnreachable: Strings.errorServerUnreachable
        case .server: Strings.errorServer
        case .unauthorized: Strings.errorUnauthorized
        case .rateLimited: Strings.errorRateLimited
        case .storage: Strings.errorStorage
        case .keychain: Strings.errorKeychain
        case .notSetUp: Strings.errorNotSetUp
        case .fileTooLarge: Strings.errorFileTooLarge
        case .unreadableFile: Strings.errorUnreadableFile
        case .notUploadedYet: Strings.errorNotUploadedYet
        case .downloadFailed: Strings.errorDownloadFailed
        case .unknown: Strings.errorUnknown
        }
    }

    /// Maps any error from the app, sync, store or crypto layers to a message.
    public init(_ error: any Error) {
        switch error {
        case let error as SyncError:
            switch error {
            case .emptyText: self = .emptyText
            case .opTooLarge: self = .tooLarge
            case .invalidPairingCode: self = .invalidCode
            case .pairingNotFound: self = .codeNotFound
            case .pairingDecryptionFailed: self = .codeMismatch
            case .missingSeq: self = .server
            case .expiryStalled: self = .storage
            case .blobsUnavailable: self = .unknown
            case .fileTooLarge: self = .fileTooLarge
            case .unreadableFile: self = .unreadableFile
            }
        case let error as BlobTransferError:
            switch error {
            case .notUploadedYet: self = .notUploadedYet
            case .corruptChunk, .relayCountMismatch, .invalidBlobRef: self = .downloadFailed
            case .noLocalCopy, .notABlobItem: self = .unknown
            }
        case let error as BlobCacheError:
            switch error {
            case .hashMismatch, .wrongChunkLength: self = .downloadFailed
            case .tooLarge: self = .fileTooLarge
            case .missing, .io: self = .storage
            }
        case let error as TransportError:
            switch error {
            case .network: self = .serverUnreachable
            case .unauthorized: self = .unauthorized
            case .rateLimited: self = .rateLimited
            case .payloadTooLarge: self = .tooLarge
            case .notFound, .conflict, .cursorAhead, .badRequest, .server, .decoding: self = .server
            }
        case let error as AppError:
            switch error {
            case .invalidServerURL: self = .invalidServer
            case .notSetUp: self = .notSetUp
            case .keyStore: self = .keychain
            }
        case is StoreError: self = .storage
        case is CryptoError: self = .unknown
        default: self = .unknown
        }
    }
}
