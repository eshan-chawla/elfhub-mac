//
//  ChatGPTPlanAccount.swift
//  elfhub
//
//  The one ChatGPT account elfhub can use for "Continue with ChatGPT": signs
//  in through the system browser, keeps the tokens in the Keychain, renews
//  the hourly access token before it runs out, lists the account's models,
//  and signs out (ending the renewable session at OpenAI).
//
//  Only two OpenAI hosts are contacted: auth.openai.com (sign-in, renewal,
//  sign-out, the signing keys) and api.openai.com (models). Tokens are never
//  printed, and the authorize URL is never logged because a returning
//  sign-in carries the previous ID token in it.
//

import AppKit
import Combine
import Foundation
import os

/// Where the account keeps what must survive a relaunch. The real one uses
/// the Keychain (tokens, registration) and UserDefaults (non-secret ids);
/// tests use an in-memory one.
struct ChatGPTPlanAccountStorage {
    var loadCredentials: @MainActor () -> ChatGPTPlanCredentials?
    var saveCredentials: @MainActor (ChatGPTPlanCredentials?) -> Void
    var loadRegistration: @MainActor () -> ChatGPTPlanRegistration?
    var saveRegistration: @MainActor (ChatGPTPlanRegistration?) -> Void
    /// The stable id for this Mac's installation, made once.
    var loadOrCreateHostIdentifier: @MainActor () -> String
    var loadHasShownPlanWelcome: @MainActor () -> Bool
    var saveHasShownPlanWelcome: @MainActor (Bool) -> Void

    static let credentialsKeychainAccount = "chatgpt-plan-credentials"
    static let registrationKeychainAccount = "chatgpt-plan-registration"
    static let hostIdentifierDefaultsKey = "chatGPTPlanHostIdentifier"
    static let hasShownPlanWelcomeDefaultsKey = "chatGPTPlanHasShownWelcome"

    static let keychainAndUserDefaults = ChatGPTPlanAccountStorage(
        loadCredentials: {
            decodedValue(ChatGPTPlanCredentials.self, fromKeychainAccount: credentialsKeychainAccount)
        },
        saveCredentials: { credentials in
            saveEncodedValue(credentials, toKeychainAccount: credentialsKeychainAccount)
        },
        loadRegistration: {
            decodedValue(ChatGPTPlanRegistration.self, fromKeychainAccount: registrationKeychainAccount)
        },
        saveRegistration: { registration in
            saveEncodedValue(registration, toKeychainAccount: registrationKeychainAccount)
        },
        loadOrCreateHostIdentifier: {
            if let savedHostIdentifier = UserDefaults.standard.string(forKey: hostIdentifierDefaultsKey), !savedHostIdentifier.isEmpty {
                return savedHostIdentifier
            }
            let newHostIdentifier = ChatGPTPlanHostIdentifier.makeNew()
            UserDefaults.standard.set(newHostIdentifier, forKey: hostIdentifierDefaultsKey)
            return newHostIdentifier
        },
        loadHasShownPlanWelcome: {
            UserDefaults.standard.bool(forKey: hasShownPlanWelcomeDefaultsKey)
        },
        saveHasShownPlanWelcome: { hasShownPlanWelcome in
            UserDefaults.standard.set(hasShownPlanWelcome, forKey: hasShownPlanWelcomeDefaultsKey)
        }
    )

    private static func decodedValue<Value: Decodable>(_ valueType: Value.Type, fromKeychainAccount keychainAccount: String) -> Value? {
        guard let storedJSON = KeychainSecretStore.secret(forAccount: keychainAccount) else { return nil }
        return try? JSONDecoder().decode(valueType, from: Data(storedJSON.utf8))
    }

    private static func saveEncodedValue<Value: Encodable>(_ value: Value?, toKeychainAccount keychainAccount: String) {
        guard let value, let encodedData = try? JSONEncoder().encode(value) else {
            KeychainSecretStore.deleteSecret(forAccount: keychainAccount)
            return
        }
        KeychainSecretStore.setSecret(String(decoding: encodedData, as: UTF8.self), forAccount: keychainAccount)
    }
}

/// One model the signed-in account may use, as listed by OpenAI.
struct ChatGPTPlanModel: Equatable, Identifiable {
    let slug: String
    let displayName: String
    var id: String { slug }

    /// Keeps entries meant for a model picker (`visibility == "list"`), in
    /// the server's order.
    static func parseModelList(fromResponseData responseData: Data) -> [ChatGPTPlanModel] {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let modelEntries = json["models"] as? [[String: Any]] else {
            return []
        }
        return modelEntries.compactMap { modelEntry in
            guard modelEntry["visibility"] as? String == "list",
                  let slug = modelEntry["slug"] as? String, !slug.isEmpty else { return nil }
            let displayName = modelEntry["display_name"] as? String
            return ChatGPTPlanModel(slug: slug, displayName: (displayName?.isEmpty == false ? displayName : nil) ?? slug)
        }
    }
}

@MainActor
final class ChatGPTPlanAccount: ObservableObject {

    /// The app's one account object; providers built for a turn ask it for
    /// a fresh access token.
    static let shared = ChatGPTPlanAccount()

    enum SignInStatus: Equatable {
        case signedOut
        case signingIn
        /// `canUsePlan` is false when the user signed in but didn't allow
        /// elfhub to use their ChatGPT plan.
        case signedIn(email: String?, canUsePlan: Bool)
        /// The saved session can't be renewed any more; the next "Continue
        /// with ChatGPT" reuses the same registration.
        case needsSignInAgain(email: String?)
    }

    @Published private(set) var signInStatus: SignInStatus = .signedOut
    /// The last sign-in or sign-out problem, shown on the ChatGPT card.
    @Published private(set) var lastProblemMessage: String?
    /// True once, right after the first sign-in that can use the plan.
    @Published private(set) var shouldShowPlanWelcome = false

    /// True when requests may be sent with this account's plan.
    var canUsePlan: Bool {
        if case .signedIn(_, true) = signInStatus { return true }
        return false
    }

    var signedInEmail: String? { credentials?.email ?? registration?.email }

    /// True when a previous sign-in left a registration to reuse.
    var hasSavedRegistration: Bool { registration != nil }

    /// Fires after every successful sign-in (the store ends a usage-limit
    /// pause then, since a new session can answer straight away).
    let signInCompletedPublisher = PassthroughSubject<Void, Never>()
    /// Set by a successful sign-in until the settings card has set up the
    /// ChatGPT model, so that happens once and never just because Settings
    /// was opened again.
    private var hasNewlyCompletedSignIn = false

    typealias HTTPRequestPerformer = @MainActor (URLRequest) async throws -> (Data, URLResponse)

    private let storage: ChatGPTPlanAccountStorage
    private let performHTTPRequest: HTTPRequestPerformer
    private let openURLInBrowser: @MainActor (URL) -> Void
    private let currentDate: @MainActor () -> Date

    private var credentials: ChatGPTPlanCredentials?
    private var registration: ChatGPTPlanRegistration?
    private var discoveryDocument: ChatGPTPlanDiscoveryDocument?
    private var signInTask: Task<Void, Never>?
    private var activeCallbackListener: LoopbackOAuthCallbackListener?
    /// The one renewal in flight: refresh tokens rotate, so two renewals at
    /// once would make one of them use an already-spent token.
    private var refreshTask: Task<ChatGPTPlanCredentials, Error>?

    init(
        storage: ChatGPTPlanAccountStorage = .keychainAndUserDefaults,
        performHTTPRequest: HTTPRequestPerformer? = nil,
        openURLInBrowser: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        currentDate: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.storage = storage
        self.openURLInBrowser = openURLInBrowser
        self.currentDate = currentDate
        if let performHTTPRequest {
            self.performHTTPRequest = performHTTPRequest
        } else {
            // No cookies or cache: nothing from the sign-in lingers on disk.
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 30
            let authenticationSession = URLSession(configuration: sessionConfiguration)
            self.performHTTPRequest = { urlRequest in try await authenticationSession.data(for: urlRequest) }
        }
        credentials = storage.loadCredentials()
        registration = storage.loadRegistration()
        if let credentials {
            signInStatus = .signedIn(email: credentials.email, canUsePlan: credentials.hasPlanUsageScope)
        }
    }

    // MARK: - Sign in

    /// Opens the browser for "Continue with ChatGPT". With
    /// `asDifferentAccount`, signs in as a new registration so the user can
    /// pick another ChatGPT account or workspace; the saved one is replaced
    /// only once that sign-in succeeds. With
    /// `requestingPlanConsent`, OpenAI shows the consent screen again so the
    /// user can allow plan use they declined before.
    func startSignIn(asDifferentAccount: Bool = false, requestingPlanConsent: Bool = false) {
        guard signInStatus != .signingIn else { return }
        let statusBeforeSignIn = signInStatus
        signInStatus = .signingIn
        lastProblemMessage = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performSignIn(
                    asDifferentAccount: asDifferentAccount,
                    requestingPlanConsent: requestingPlanConsent
                )
            } catch {
                self.activeCallbackListener?.stop()
                self.activeCallbackListener = nil
                self.signInStatus = statusBeforeSignIn
                // A cancelled sign-in can surface as URLSession's own
                // "cancelled" error; either way the user chose it.
                if !(error is CancellationError) && !Task.isCancelled {
                    self.lastProblemMessage = error.localizedDescription
                }
            }
            self.signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        activeCallbackListener?.stop()
    }

    /// True once after each successful sign-in; reading it clears it.
    func consumeNewlyCompletedSignIn() -> Bool {
        let wasNewlyCompleted = hasNewlyCompletedSignIn
        hasNewlyCompletedSignIn = false
        return wasNewlyCompleted
    }

    private func performSignIn(asDifferentAccount: Bool, requestingPlanConsent: Bool) async throws {
        let discoveryDocument = try await loadDiscoveryDocument()
        try Task.checkCancellation()
        let callbackListener = try await LoopbackOAuthCallbackListener.start()
        activeCallbackListener = callbackListener
        defer {
            callbackListener.stop()
            activeCallbackListener = nil
        }
        // Cancel may have been pressed while the listener started; never
        // open the browser for a sign-in nobody is waiting for.
        try Task.checkCancellation()

        // Another account registers anew, so it carries no saved client id
        // or hints, and the saved registration isn't checked against it.
        let registrationToReuse = asDifferentAccount ? nil : registration
        let authorizationRequest = ChatGPTPlanAuthorizationRequest.makeFresh(
            authorizationEndpoint: discoveryDocument.authorizationEndpoint,
            redirectURI: callbackListener.redirectURI,
            hostIdentifier: storage.loadOrCreateHostIdentifier(),
            savedIssuedClientIdentifier: registrationToReuse?.issuedClientIdentifier,
            idTokenHint: registrationToReuse == nil ? nil : credentials?.idToken,
            loginHint: registrationToReuse?.email,
            requestsConsentAgain: requestingPlanConsent
        )
        callbackListener.expectedState = authorizationRequest.state
        openURLInBrowser(authorizationRequest.authorizationURL)

        let callbackQueryItems = try await callbackListener.waitForCallback()
        let validatedCallback = try authorizationRequest.validatedCallback(fromQueryItems: callbackQueryItems)

        var tokenRequest = URLRequest(url: discoveryDocument.tokenEndpoint)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.httpBody = authorizationRequest.tokenExchangeFormBody(
            authorizationCode: validatedCallback.authorizationCode,
            clientIdentifier: validatedCallback.clientIdentifier
        )
        let tokenResponse = try await performTokenRequest(tokenRequest)
        guard let idToken = tokenResponse.idToken, let refreshToken = tokenResponse.refreshToken else {
            throw ChatGPTPlanSignInError.invalidTokenResponse
        }

        let jwksData = try await performGET(discoveryDocument.jwksURI)
        let verifiedClaims = try ChatGPTPlanIDTokenValidator.validatedClaims(
            idToken: idToken,
            jwksData: jwksData,
            expectedIssuer: discoveryDocument.issuer,
            expectedAudience: validatedCallback.clientIdentifier,
            expectedNonce: authorizationRequest.nonce,
            now: currentDate()
        )
        // A saved registration belongs to one account; never put another
        // account's tokens under it.
        if let registrationToReuse, registrationToReuse.subject != verifiedClaims.subject {
            throw ChatGPTPlanSignInError.differentAccount
        }

        let signInDate = currentDate()
        let newCredentials = ChatGPTPlanCredentials(
            email: verifiedClaims.email,
            subject: verifiedClaims.subject,
            clientIdentifier: validatedCallback.clientIdentifier,
            hostIdentifier: authorizationRequest.hostIdentifier,
            idToken: idToken,
            accessToken: tokenResponse.accessToken,
            refreshToken: refreshToken,
            accessTokenExpiryDate: signInDate.addingTimeInterval(TimeInterval(tokenResponse.expiresInSeconds ?? 3600)),
            // OAuth leaves `scope` out when everything requested was granted.
            grantedScopes: tokenResponse.grantedScopes ?? ChatGPTPlanOAuthConstants.requestedScopes,
            savedDate: signInDate
        )
        let newRegistration = ChatGPTPlanRegistration(
            issuedClientIdentifier: validatedCallback.clientIdentifier,
            subject: verifiedClaims.subject,
            email: verifiedClaims.email
        )
        // Tokens of another registration (the user chose a different
        // account) belong to a session nothing will use again; it's ended
        // at OpenAI below. Tokens of this same registration are left alone,
        // since revoking them might end the session just created.
        let replacedCredentials = credentials
        credentials = newCredentials
        registration = newRegistration
        storage.saveCredentials(newCredentials)
        storage.saveRegistration(newRegistration)
        signInStatus = .signedIn(email: newCredentials.email, canUsePlan: newCredentials.hasPlanUsageScope)
        hasNewlyCompletedSignIn = true
        signInCompletedPublisher.send()

        if newCredentials.hasPlanUsageScope, !storage.loadHasShownPlanWelcome() {
            shouldShowPlanWelcome = true
        }

        if let replacedCredentials, replacedCredentials.clientIdentifier != newCredentials.clientIdentifier {
            _ = await revokeRenewableSession(of: replacedCredentials)
        }
    }

    func dismissPlanWelcome() {
        shouldShowPlanWelcome = false
        storage.saveHasShownPlanWelcome(true)
    }

    // MARK: - Sign out

    /// Ends the renewable session at OpenAI and clears the tokens. Keeps the
    /// registration so the next sign-in doesn't add another app to the
    /// user's ChatGPT settings.
    func signOut() async {
        cancelSignIn()
        // A renewal in flight isn't cancelled: OpenAI may already have
        // rotated the refresh token, so it finishes and revokes the new one
        // itself (see `renewAccessToken`).
        refreshTask = nil
        guard let signedOutCredentials = credentials else {
            signInStatus = .signedOut
            return
        }
        credentials = nil
        storage.saveCredentials(nil)
        signInStatus = .signedOut
        lastProblemMessage = nil

        let revocationConfirmed = await revokeRenewableSession(of: signedOutCredentials)
        if !revocationConfirmed {
            lastProblemMessage = "Signed out on this Mac, but ChatGPT didn't confirm it. You can also disconnect elfhub in ChatGPT's settings."
        }
    }

    private func revokeRenewableSession(of signedOutCredentials: ChatGPTPlanCredentials) async -> Bool {
        guard let revocationEndpoint = try? await loadDiscoveryDocument().revocationEndpoint else { return false }
        var revocationRequest = URLRequest(url: revocationEndpoint)
        revocationRequest.httpMethod = "POST"
        revocationRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        revocationRequest.httpBody = ChatGPTPlanTokenRequests.revocationFormBody(
            refreshToken: signedOutCredentials.refreshToken,
            clientIdentifier: signedOutCredentials.clientIdentifier
        )
        // Network failures and 5xx are retried a couple of times; an
        // already-invalid token still answers 200.
        for attemptNumber in 1...3 {
            if let (_, response) = try? await performHTTPRequest(revocationRequest),
               let statusCode = (response as? HTTPURLResponse)?.statusCode {
                if (200...299).contains(statusCode) { return true }
                if statusCode < 500 { return false }
            }
            if attemptNumber < 3 {
                try? await Task.sleep(nanoseconds: UInt64(attemptNumber) * 1_000_000_000)
            }
        }
        return false
    }

    // MARK: - Access token

    /// A usable access token for a request, renewed first when it has less
    /// than five minutes left (or when `forcingRefresh`, after a 401).
    func validAccessToken(forcingRefresh: Bool = false) async throws -> String {
        guard let currentCredentials = credentials else {
            throw ChatGPTPlanSignInError.signInRequired
        }
        guard currentCredentials.hasPlanUsageScope else {
            throw ChatGPTPlanUsageError.planUsageNotEnabled
        }
        if !forcingRefresh, !currentCredentials.needsRefresh(now: currentDate()) {
            return currentCredentials.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let newRefreshTask = Task { [weak self] () throws -> ChatGPTPlanCredentials in
            guard let self else { throw CancellationError() }
            return try await self.renewAccessToken(of: currentCredentials)
        }
        refreshTask = newRefreshTask
        defer {
            // Sign-out may have let go of this renewal and a newer one may
            // have started since; only clear the slot if it's still ours.
            if refreshTask == newRefreshTask {
                refreshTask = nil
            }
        }
        return try await newRefreshTask.value.accessToken
    }

    private func renewAccessToken(of currentCredentials: ChatGPTPlanCredentials) async throws -> ChatGPTPlanCredentials {
        let discoveryDocument = try await loadDiscoveryDocument()
        var refreshRequest = URLRequest(url: discoveryDocument.tokenEndpoint)
        refreshRequest.httpMethod = "POST"
        refreshRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        refreshRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        refreshRequest.httpBody = ChatGPTPlanTokenRequests.refreshFormBody(
            refreshToken: currentCredentials.refreshToken,
            clientIdentifier: currentCredentials.clientIdentifier
        )

        let (responseData, response) = try await performHTTPRequest(refreshRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            if ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: String(decoding: responseData, as: UTF8.self)) {
                // These tokens can never be renewed. Clear them, keep the
                // registration, and ask the user to sign in again.
                credentials = nil
                storage.saveCredentials(nil)
                signInStatus = .needsSignInAgain(email: currentCredentials.email)
                throw ChatGPTPlanSignInError.signInRequired
            }
            // A temporary problem: keep the tokens and let the caller retry.
            throw ChatGPTPlanSignInError.tokenRequestFailed(statusCode: statusCode)
        }
        guard let refreshResponse = try? JSONDecoder().decode(ChatGPTPlanTokenResponse.self, from: responseData) else {
            throw ChatGPTPlanSignInError.invalidTokenResponse
        }

        let refreshedCredentials = currentCredentials.replacingTokens(with: refreshResponse, now: currentDate())
        // The user may have signed out (or signed in again) while this was
        // in flight. The renewed session belongs to nobody now: end it.
        guard credentials?.refreshToken == currentCredentials.refreshToken else {
            if refreshedCredentials.refreshToken != currentCredentials.refreshToken {
                _ = await revokeRenewableSession(of: refreshedCredentials)
            }
            throw CancellationError()
        }
        credentials = refreshedCredentials
        storage.saveCredentials(refreshedCredentials)
        signInStatus = .signedIn(email: refreshedCredentials.email, canUsePlan: refreshedCredentials.hasPlanUsageScope)
        return refreshedCredentials
    }

    // MARK: - Models

    /// The models this account may use, for the model picker.
    func listModels() async throws -> [ChatGPTPlanModel] {
        let accessToken = try await validAccessToken()
        var modelsRequest = URLRequest(url: URL(string: "\(ChatGPTPlanOAuthConstants.resource)/models")!)
        modelsRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        modelsRequest.timeoutInterval = 15
        let (responseData, response) = try await performHTTPRequest(modelsRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw ChatGPTPlanUsageError.from(
                LanguageModelProviderError.httpError(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
            ) ?? LanguageModelProviderError.httpError(statusCode: statusCode, body: "")
        }
        return ChatGPTPlanModel.parseModelList(fromResponseData: responseData)
    }

    // MARK: - HTTP helpers

    private func loadDiscoveryDocument() async throws -> ChatGPTPlanDiscoveryDocument {
        if let discoveryDocument { return discoveryDocument }
        let discoveryData: Data
        do {
            discoveryData = try await performGET(ChatGPTPlanOAuthConstants.discoveryDocumentURL)
        } catch {
            throw ChatGPTPlanSignInError.discoveryFailed
        }
        guard let loadedDocument = try? JSONDecoder().decode(ChatGPTPlanDiscoveryDocument.self, from: discoveryData),
              loadedDocument.issuer == ChatGPTPlanOAuthConstants.expectedIssuer else {
            throw ChatGPTPlanSignInError.discoveryFailed
        }
        discoveryDocument = loadedDocument
        return loadedDocument
    }

    private func performGET(_ url: URL) async throws -> Data {
        let (responseData, response) = try await performHTTPRequest(URLRequest(url: url))
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            throw ChatGPTPlanSignInError.tokenRequestFailed(statusCode: statusCode)
        }
        return responseData
    }

    private func performTokenRequest(_ tokenRequest: URLRequest) async throws -> ChatGPTPlanTokenResponse {
        let (responseData, response) = try await performHTTPRequest(tokenRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let openAIReason = ChatGPTPlanTokenRequests.oauthErrorReason(
                fromResponseBody: String(decoding: responseData, as: UTF8.self)
            )
            companionLogger.error("ChatGPT code exchange rejected: HTTP \(statusCode, privacy: .public) \(openAIReason ?? "no reason given", privacy: .public)")
            throw ChatGPTPlanSignInError.codeExchangeRejected(statusCode: statusCode, openAIReason: openAIReason)
        }
        guard let tokenResponse = try? JSONDecoder().decode(ChatGPTPlanTokenResponse.self, from: responseData) else {
            throw ChatGPTPlanSignInError.invalidTokenResponse
        }
        return tokenResponse
    }
}
