import Foundation
import MedTrackerSync
import Observation

public enum AuthPhase: Equatable {
    case launching
    case disclaimerConsent
    case unauthenticated(error: AuthError?)
    case totpChallenge(preAuthToken: String, error: AuthError?)
    case firstSync(FirstSyncState)
    case authenticated
}

public enum AuthError: Equatable {
    case invalidCredentials, incorrectCode
    case rateLimited(retryAfter: Int)
    case transport, server, sessionExpired, emailConflict
}

public struct FirstSyncState: Equatable, Sendable {
    public var pulledMedications: Int
    public var pulledDoseLogs: Int
    public var isIndeterminate: Bool
    public init(pulledMedications: Int = 0, pulledDoseLogs: Int = 0, isIndeterminate: Bool = true) {
        self.pulledMedications = pulledMedications
        self.pulledDoseLogs = pulledDoseLogs
        self.isIndeterminate = isIndeterminate
    }
}

/// The single source of truth for which root view renders (§3.1). `@MainActor` + `SyncEngine`-actor
/// means the only data-race surface is `await` suspension; there is no shared mutable state to guard.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var phase: AuthPhase = .launching

    /// Backs the sidebar sync-status indicator (§2.5/§3.4.3). Updated only inside `runSync()`.
    public private(set) var lastSyncedAt: Date?
    public private(set) var isSyncing = false
    /// A non-blocking banner for a non-401 sync failure while authenticated (§3.3) — never a
    /// logout. Cleared on the next successful `runSync()`.
    public private(set) var lastSyncError: AuthError?

    private let env: AppEnvironment
    private let defaults: UserDefaults
    private static let disclaimerKey = "disclaimerAcknowledged"

    private enum AuthContext { case login, totp }

    public init(env: AppEnvironment, defaults: UserDefaults = .standard) {
        self.env = env
        self.defaults = defaults
    }

    // MARK: launch + consent

    /// `.launching` → consent flag → token check. On relaunch with a token we enter the shell and
    /// kick a refresh (a stale token is discovered lazily by `runSync`), never a re-auth round-trip.
    public func start() async {
        phase = .launching
        guard defaults.bool(forKey: Self.disclaimerKey) else {
            phase = .disclaimerConsent
            return
        }
        resolveEntry()
        if case .authenticated = phase { await runSync() }
    }

    /// Persist the consent flag and proceed to the token check (§3.1).
    public func acknowledgeDisclaimer() {
        defaults.set(true, forKey: Self.disclaimerKey)
        resolveEntry()
    }

    private func resolveEntry() {
        let session = try? env.tokenStore.load()
        phase = (session == nil) ? .unauthenticated(error: nil) : .authenticated
    }

    // MARK: login / TOTP / SIWA

    public func signIn(email: String, password: String) async {
        do {
            let outcome = try await env.syncEngine.login(email: email, password: password)
            switch outcome {
            case .session:
                phase = .firstSync(FirstSyncState())            // engine persisted the session
            case let .totpChallenge(preAuthToken):
                phase = .totpChallenge(preAuthToken: preAuthToken, error: nil)   // nothing persisted yet
            }
        } catch {
            phase = .unauthenticated(error: authError(for: error, context: .login))
        }
    }

    public func verify(code: String) async {
        guard case let .totpChallenge(preAuthToken, _) = phase else { return }
        do {
            _ = try await env.syncEngine.verifyTOTP(preAuthToken: preAuthToken, code: code)
            phase = .firstSync(FirstSyncState())
        } catch {
            phase = .totpChallenge(preAuthToken: preAuthToken,
                                   error: authError(for: error, context: .totp))   // token retained
        }
    }

    public func signInWithApple(identityToken: String, fullName: String?) async {
        do {
            _ = try await env.syncEngine.signInWithApple(identityToken: identityToken, fullName: fullName)
            phase = .firstSync(FirstSyncState())
        } catch {
            phase = .unauthenticated(error: authError(for: error, context: .login))
        }
    }

    // MARK: the single sync funnel (§3.3)

    /// The ONLY place `SyncEngine.sync()` is invoked. `APIError.unauthorized` is the sole re-auth
    /// signal: clear the session and drop to `.unauthenticated(.sessionExpired)`. Every other error
    /// leaves the session intact — during `.firstSync` we still enter the shell (offline-tolerant,
    /// §3.3); while `.authenticated` we surface `lastSyncError`. `isSyncing`/`lastSyncedAt` back the
    /// sidebar sync-status indicator (§2.5/§3.4.3).
    public func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcome = try await env.syncEngine.sync()
            _ = outcome   // 1c reveals the shell on completion; pulled counts feed the progress UI
            lastSyncedAt = Date()
            lastSyncError = nil
            if case .firstSync = phase {
                phase = .authenticated
            }
        } catch APIError.unauthorized {
            try? env.tokenStore.clear()
            lastSyncError = .sessionExpired
            phase = .unauthenticated(error: .sessionExpired)
        } catch {
            let mapped = authError(for: error, context: .login)
            lastSyncError = mapped
            if case .firstSync = phase {
                phase = .authenticated           // enter with whatever local data exists + a banner
            }
        }
    }

    public func signOut() {
        try? env.tokenStore.clear()
        phase = .unauthenticated(error: nil)
    }

    // MARK: error mapping

    private func authError(for error: Error, context: AuthContext) -> AuthError {
        switch error {
        case APIError.unauthorized, APIError.badRequest:
            return context == .totp ? .incorrectCode : .invalidCredentials
        case let APIError.rateLimited(retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case APIError.emailConflict:
            return .emailConflict
        case APIError.transport:
            return .transport
        default:
            return .server   // .server(status:) / .decoding / anything unexpected
        }
    }
}
