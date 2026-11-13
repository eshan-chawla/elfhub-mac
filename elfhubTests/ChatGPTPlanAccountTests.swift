//
//  ChatGPTPlanAccountTests.swift
//  elfhubTests
//
//  The ChatGPT account's token handling with in-memory storage and a fake
//  HTTP layer: a fresh token is used as is, a nearly expired one is renewed
//  once even when two turns ask together, a terminal refresh error asks for
//  a new sign-in while a temporary one keeps the tokens, sign-out revokes
//  the session and keeps the registration, and the loopback listener
//  returns the browser's callback.
//

import Foundation
import Testing
@testable import elfhub

@MainActor
final class InMemoryChatGPTPlanStorageBox {
    var credentials: ChatGPTPlanCredentials?
    var registration: ChatGPTPlanRegistration?
    var hasShownPlanWelcome = false

    var storage: ChatGPTPlanAccountStorage {
        ChatGPTPlanAccountStorage(
            loadCredentials: { self.credentials },
            saveCredentials: { self.credentials = $0 },
            loadRegistration: { self.registration },
            saveRegistration: { self.registration = $0 },
            loadOrCreateHostIdentifier: { "urn:uuid:11111111-2222-3333-4444-555555555555" },
            loadHasShownPlanWelcome: { self.hasShownPlanWelcome },
            saveHasShownPlanWelcome: { self.hasShownPlanWelcome = $0 }
        )
    }
}

@MainActor
final class FakeAuthenticationServer {
    var requestedURLs: [URL] = []
    var refreshResponses: [(Int, String)] = []
    /// For the code exchange: the ID token to hand back, made once the
    /// browser step has revealed the nonce.
    var makeIDTokenForCodeExchange: ((_ nonce: String) throws -> String)?
    var nonceFromAuthorizeURL: String?
    var jwksData = Data()
    /// nil leaves `scope` out of the code-exchange response.
    var grantedScopeForCodeExchange: String? = "openid email offline_access resource.invoke chatgpt.tokens.use.direct"
    var revocationStatusCode = 200
    /// The refresh tokens elfhub asked OpenAI to revoke, in order.
    var revokedRefreshTokens: [String] = []
    /// Runs just before the code exchange answers (a test can cancel there).
    var beforeCodeExchange: (@MainActor () throws -> Void)?
    /// Lets a test hold the refresh response until both callers are waiting.
    var refreshDelayInNanoseconds: UInt64 = 0

    static let discoveryJSON = #"""
    {"issuer":"https://auth.openai.com",
     "authorization_endpoint":"https://auth.openai.com/api/accounts/authorize",
     "token_endpoint":"https://auth.openai.com/api/accounts/oauth/token",
     "jwks_uri":"https://auth.openai.com/.well-known/jwks.json",
     "revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke"}
    """#

    func perform(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        let url = urlRequest.url!
        requestedURLs.append(url)
        func response(_ statusCode: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
        }
        switch url.path {
        case "/.well-known/openid-configuration":
            return response(200, Self.discoveryJSON)
        case "/.well-known/jwks.json":
            return response(200, String(decoding: jwksData, as: UTF8.self))
        case "/api/accounts/oauth/token" where String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self).contains("grant_type=authorization_code"):
            try beforeCodeExchange?()
            guard let makeIDTokenForCodeExchange, let nonceFromAuthorizeURL else { return response(400, "{}") }
            let idToken = try makeIDTokenForCodeExchange(nonceFromAuthorizeURL)
            let scopeField = grantedScopeForCodeExchange.map { #","scope":"\#($0)""# } ?? ""
            return response(200, #"{"access_token":"access-new","refresh_token":"refresh-new","id_token":"\#(idToken)","token_type":"Bearer","expires_in":3600\#(scopeField)}"#)
        case "/api/accounts/oauth/token":
            if refreshDelayInNanoseconds > 0 { try await Task.sleep(nanoseconds: refreshDelayInNanoseconds) }
            let (statusCode, body) = refreshResponses.isEmpty ? (500, "{}") : refreshResponses.removeFirst()
            return response(statusCode, body)
        case "/api/accounts/oauth/revoke":
            let revocationForm = URLComponents(string: "?" + String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self))
            if let revokedRefreshToken = revocationForm?.queryItems?.first(where: { $0.name == "token" })?.value {
                revokedRefreshTokens.append(revokedRefreshToken)
            }
            return response(revocationStatusCode, "")
        default:
            return response(404, "{}")
        }
    }

    var tokenRequestCount: Int { requestedURLs.filter { $0.path == "/api/accounts/oauth/token" }.count }
}

@MainActor
struct ChatGPTPlanAccountTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func savedCredentials(expiringIn secondsUntilExpiry: TimeInterval, scopes: [String] = ["openid", "chatgpt.tokens.use.direct"]) -> ChatGPTPlanCredentials {
        ChatGPTPlanCredentials(
            email: "person@example.com",
            subject: "user-subject",
            clientIdentifier: "oaiapp_saved",
            hostIdentifier: "urn:uuid:11111111-2222-3333-4444-555555555555",
            idToken: "id.token.value",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            accessTokenExpiryDate: referenceDate.addingTimeInterval(secondsUntilExpiry),
            grantedScopes: scopes,
            savedDate: referenceDate
        )
    }

    private func makeAccount(credentials: ChatGPTPlanCredentials?, server: FakeAuthenticationServer, storageBox: InMemoryChatGPTPlanStorageBox) -> ChatGPTPlanAccount {
        storageBox.credentials = credentials
        storageBox.registration = credentials.map {
            ChatGPTPlanRegistration(issuedClientIdentifier: $0.clientIdentifier, subject: $0.subject, email: $0.email)
        }
        return ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: { _ in },
            currentDate: { [referenceDate] in referenceDate }
        )
    }

    @Test func savedSignInIsRestoredAtLaunch() {
        let account = makeAccount(credentials: savedCredentials(expiringIn: 3600), server: FakeAuthenticationServer(), storageBox: InMemoryChatGPTPlanStorageBox())
        #expect(account.signInStatus == .signedIn(email: "person@example.com", canUsePlan: true))
        #expect(account.canUsePlan)
    }

    @Test func signInWithoutPlanPermissionCannotUseThePlan() async {
        let account = makeAccount(
            credentials: savedCredentials(expiringIn: 3600, scopes: ["openid", "email"]),
            server: FakeAuthenticationServer(),
            storageBox: InMemoryChatGPTPlanStorageBox()
        )
        #expect(!account.canUsePlan)
        await #expect(throws: ChatGPTPlanUsageError.planUsageNotEnabled) { try await account.validAccessToken() }
    }

    @Test func freshTokenIsUsedWithoutRenewing() async throws {
        let server = FakeAuthenticationServer()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 3600), server: server, storageBox: InMemoryChatGPTPlanStorageBox())
        #expect(try await account.validAccessToken() == "access-1")
        #expect(server.requestedURLs.isEmpty)
    }

    @Test func nearlyExpiredTokenIsRenewedOnceForTwoCallers() async throws {
        let server = FakeAuthenticationServer()
        server.refreshDelayInNanoseconds = 50_000_000
        server.refreshResponses = [(200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#)]
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 60), server: server, storageBox: storageBox)

        async let firstToken = account.validAccessToken()
        async let secondToken = account.validAccessToken()
        let tokens = try await [firstToken, secondToken]

        #expect(tokens == ["access-2", "access-2"])
        #expect(server.tokenRequestCount == 1)
        #expect(storageBox.credentials?.refreshToken == "refresh-2")
        #expect(storageBox.credentials?.accessTokenExpiryDate == referenceDate.addingTimeInterval(3600))
    }

    @Test func terminalRefreshErrorAsksForANewSignInAndKeepsTheRegistration() async {
        let server = FakeAuthenticationServer()
        server.refreshResponses = [(400, #"{"error":"invalid_grant"}"#)]
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 0), server: server, storageBox: storageBox)

        await #expect(throws: ChatGPTPlanSignInError.signInRequired) { try await account.validAccessToken() }
        #expect(account.signInStatus == .needsSignInAgain(email: "person@example.com"))
        #expect(storageBox.credentials == nil)
        #expect(storageBox.registration?.issuedClientIdentifier == "oaiapp_saved")
    }

    @Test func temporaryRefreshErrorKeepsTheTokens() async {
        let server = FakeAuthenticationServer()
        server.refreshResponses = [(503, "upstream unavailable")]
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 0), server: server, storageBox: storageBox)

        await #expect(throws: ChatGPTPlanSignInError.tokenRequestFailed(statusCode: 503)) { try await account.validAccessToken() }
        #expect(storageBox.credentials?.refreshToken == "refresh-1")
        #expect(account.canUsePlan)
    }

    @Test func forcedRefreshRenewsEvenAFreshToken() async throws {
        let server = FakeAuthenticationServer()
        server.refreshResponses = [(200, #"{"access_token":"access-2","expires_in":3600}"#)]
        let account = makeAccount(credentials: savedCredentials(expiringIn: 3600), server: server, storageBox: InMemoryChatGPTPlanStorageBox())
        #expect(try await account.validAccessToken(forcingRefresh: true) == "access-2")
    }

    @Test func signOutRevokesClearsTokensAndKeepsRegistration() async {
        let server = FakeAuthenticationServer()
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 3600), server: server, storageBox: storageBox)

        await account.signOut()

        #expect(account.signInStatus == .signedOut)
        #expect(storageBox.credentials == nil)
        #expect(storageBox.registration?.issuedClientIdentifier == "oaiapp_saved")
        #expect(server.requestedURLs.contains(where: { $0.path == "/api/accounts/oauth/revoke" }))
        #expect(account.lastProblemMessage == nil)
        await #expect(throws: ChatGPTPlanSignInError.signInRequired) { try await account.validAccessToken() }
    }

    @Test func unconfirmedRevocationIsReported() async {
        let server = FakeAuthenticationServer()
        server.revocationStatusCode = 400
        let account = makeAccount(credentials: savedCredentials(expiringIn: 3600), server: server, storageBox: InMemoryChatGPTPlanStorageBox())
        await account.signOut()
        #expect(account.signInStatus == .signedOut)
        #expect(account.lastProblemMessage != nil)
    }

    // MARK: - Full sign-in through a simulated browser

    /// Plays the browser: reads the authorize URL, then calls elfhub's
    /// loopback callback with a code, the same state and the issued client.
    private func makeSimulatedBrowser(
        server: FakeAuthenticationServer,
        deniesAccess: Bool = false,
        openedURLs: @escaping @MainActor (URL) -> Void
    ) -> @MainActor (URL) -> Void {
        { authorizeURL in
            openedURLs(authorizeURL)
            let queryItems = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { queryItems.first(where: { $0.name == name })?.value ?? "" }
            server.nonceFromAuthorizeURL = value("nonce")
            let issuedClientIdentifier = value("client_id") == "dynamic_agent_client" ? "oaiapp_new" : value("client_id")
            var callbackComponents = URLComponents(string: value("redirect_uri"))!
            callbackComponents.queryItems = deniesAccess
                ? [
                    URLQueryItem(name: "error", value: "access_denied"),
                    URLQueryItem(name: "state", value: value("state")),
                ]
                : [
                    URLQueryItem(name: "code", value: "the-code"),
                    URLQueryItem(name: "state", value: value("state")),
                    URLQueryItem(name: "client_id", value: issuedClientIdentifier),
                ]
            let callbackURL = callbackComponents.url!
            Task.detached { _ = try? await URLSession.shared.data(from: callbackURL) }
        }
    }

    private func waitUntilSignInFinishes(_ account: ChatGPTPlanAccount) async {
        for _ in 0..<200 where account.signInStatus == .signingIn {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private func signingServer(audience: String, subject: String = "user-subject") throws -> FakeAuthenticationServer {
        let server = FakeAuthenticationServer()
        let signingKey = try ChatGPTPlanTestSigningKey()
        server.jwksData = signingKey.jwksData
        let referenceDate = referenceDate
        server.makeIDTokenForCodeExchange = { nonce in
            try signingKey.signedToken(claims: [
                "iss": "https://auth.openai.com", "aud": audience, "sub": subject,
                "email": "person@example.com", "nonce": nonce,
                "exp": Int(referenceDate.timeIntervalSince1970) + 600,
            ])
        }
        return server
    }

    @Test func firstSignInRegistersSavesAndAsksToSetUpTheModelOnce() async throws {
        let server = try signingServer(audience: "oaiapp_new")
        let storageBox = InMemoryChatGPTPlanStorageBox()
        var openedAuthorizeURLs: [URL] = []
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, openedURLs: { openedAuthorizeURLs.append($0) }),
            currentDate: { [referenceDate] in referenceDate }
        )

        account.startSignIn()
        await waitUntilSignInFinishes(account)

        #expect(account.signInStatus == .signedIn(email: "person@example.com", canUsePlan: true))
        #expect(account.lastProblemMessage == nil)
        #expect(storageBox.registration?.issuedClientIdentifier == "oaiapp_new")
        #expect(storageBox.credentials?.accessToken == "access-new")
        #expect(account.shouldShowPlanWelcome)
        let authorizeQuery = URLComponents(url: try #require(openedAuthorizeURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!authorizeQuery.contains(where: { $0.name == "prompt" }))
        // The settings card sets up the ChatGPT model only right after a sign-in.
        #expect(account.consumeNewlyCompletedSignIn())
        #expect(!account.consumeNewlyCompletedSignIn())
    }

    @Test func allowingThePlanAfterADeclineAsksForConsentAgain() async throws {
        let server = try signingServer(audience: "oaiapp_saved")
        let storageBox = InMemoryChatGPTPlanStorageBox()
        var openedAuthorizeURLs: [URL] = []
        storageBox.credentials = savedCredentials(expiringIn: 3600, scopes: ["openid", "email"])
        storageBox.registration = ChatGPTPlanRegistration(issuedClientIdentifier: "oaiapp_saved", subject: "user-subject", email: "person@example.com")
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, openedURLs: { openedAuthorizeURLs.append($0) }),
            currentDate: { [referenceDate] in referenceDate }
        )
        #expect(!account.canUsePlan)

        account.startSignIn(requestingPlanConsent: true)
        await waitUntilSignInFinishes(account)

        let authorizeQuery = URLComponents(url: try #require(openedAuthorizeURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authorizeQuery.first(where: { $0.name == "prompt" })?.value == "consent")
        #expect(authorizeQuery.first(where: { $0.name == "client_id" })?.value == "oaiapp_saved")
        #expect(account.canUsePlan)
    }

    @Test func cancellingBeforeTheBrowserOpensNeverOpensIt() async {
        let server = FakeAuthenticationServer()
        let storageBox = InMemoryChatGPTPlanStorageBox()
        var openedAuthorizeURLs: [URL] = []
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: { openedAuthorizeURLs.append($0) },
            currentDate: { [referenceDate] in referenceDate }
        )

        account.startSignIn()
        account.cancelSignIn()
        await waitUntilSignInFinishes(account)

        #expect(openedAuthorizeURLs.isEmpty)
        #expect(account.signInStatus == .signedOut)
        #expect(account.lastProblemMessage == nil)
    }

    @Test func cancellingDuringTheCodeExchangeShowsNoProblem() async throws {
        let server = try signingServer(audience: "oaiapp_new")
        let storageBox = InMemoryChatGPTPlanStorageBox()
        var accountToCancel: ChatGPTPlanAccount?
        // What URLSession throws when the task waiting on it is cancelled.
        server.beforeCodeExchange = {
            accountToCancel?.cancelSignIn()
            throw URLError(.cancelled)
        }
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, openedURLs: { _ in }),
            currentDate: { [referenceDate] in referenceDate }
        )
        accountToCancel = account

        account.startSignIn()
        await waitUntilSignInFinishes(account)

        #expect(account.signInStatus == .signedOut)
        #expect(account.lastProblemMessage == nil)
    }

    @Test func signingOutDuringARenewalRevokesTheRenewedSession() async {
        let server = FakeAuthenticationServer()
        server.refreshDelayInNanoseconds = 100_000_000
        server.refreshResponses = [(200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#)]
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = makeAccount(credentials: savedCredentials(expiringIn: 60), server: server, storageBox: storageBox)

        async let renewedAccessToken = account.validAccessToken()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await account.signOut()
        _ = try? await renewedAccessToken

        #expect(server.revokedRefreshTokens.contains("refresh-1"))
        #expect(server.revokedRefreshTokens.contains("refresh-2"))
        #expect(storageBox.credentials == nil)
        #expect(account.signInStatus == .signedOut)
    }

    @Test func choosingADifferentAccountKeepsTheRegistrationWhenTheSignInFails() async throws {
        let server = FakeAuthenticationServer()
        let storageBox = InMemoryChatGPTPlanStorageBox()
        var openedAuthorizeURLs: [URL] = []
        storageBox.credentials = savedCredentials(expiringIn: 3600)
        storageBox.registration = ChatGPTPlanRegistration(issuedClientIdentifier: "oaiapp_saved", subject: "user-subject", email: "person@example.com")
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, deniesAccess: true, openedURLs: { openedAuthorizeURLs.append($0) }),
            currentDate: { [referenceDate] in referenceDate }
        )

        account.startSignIn(asDifferentAccount: true)
        await waitUntilSignInFinishes(account)

        let authorizeQuery = URLComponents(url: try #require(openedAuthorizeURLs.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authorizeQuery.first(where: { $0.name == "client_id" })?.value == "dynamic_agent_client")
        #expect(!authorizeQuery.contains(where: { $0.name == "id_token_hint" }))
        #expect(storageBox.registration?.issuedClientIdentifier == "oaiapp_saved")
        #expect(account.hasSavedRegistration)
        #expect(account.signInStatus == .signedIn(email: "person@example.com", canUsePlan: true))
        #expect(account.lastProblemMessage != nil)
    }

    @Test func choosingADifferentAccountReplacesTheRegistrationAndEndsTheOldSession() async throws {
        let server = try signingServer(audience: "oaiapp_new", subject: "other-subject")
        let storageBox = InMemoryChatGPTPlanStorageBox()
        storageBox.credentials = savedCredentials(expiringIn: 3600)
        storageBox.registration = ChatGPTPlanRegistration(issuedClientIdentifier: "oaiapp_saved", subject: "user-subject", email: "person@example.com")
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, openedURLs: { _ in }),
            currentDate: { [referenceDate] in referenceDate }
        )

        account.startSignIn(asDifferentAccount: true)
        await waitUntilSignInFinishes(account)

        #expect(account.lastProblemMessage == nil)
        #expect(storageBox.registration?.subject == "other-subject")
        #expect(storageBox.registration?.issuedClientIdentifier == "oaiapp_new")
        #expect(storageBox.credentials?.refreshToken == "refresh-new")
        #expect(server.revokedRefreshTokens == ["refresh-1"])
    }

    @Test func tokenResponseWithoutScopeMeansTheRequestedScopesWereGranted() async throws {
        let server = try signingServer(audience: "oaiapp_new")
        server.grantedScopeForCodeExchange = nil
        let storageBox = InMemoryChatGPTPlanStorageBox()
        let account = ChatGPTPlanAccount(
            storage: storageBox.storage,
            performHTTPRequest: { try await server.perform($0) },
            openURLInBrowser: makeSimulatedBrowser(server: server, openedURLs: { _ in }),
            currentDate: { [referenceDate] in referenceDate }
        )

        account.startSignIn()
        await waitUntilSignInFinishes(account)

        #expect(account.signInStatus == .signedIn(email: "person@example.com", canUsePlan: true))
    }

    // MARK: - Loopback listener

    @Test func callbackRequestLineIsParsed() {
        let queryItems = LoopbackOAuthCallbackListener.callbackQueryItems(
            fromHTTPRequest: "GET /auth/callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n",
            callbackPath: "/auth/callback"
        )
        #expect(queryItems?.first(where: { $0.name == "code" })?.value == "abc")
        #expect(LoopbackOAuthCallbackListener.callbackQueryItems(fromHTTPRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n", callbackPath: "/auth/callback") == nil)
        #expect(LoopbackOAuthCallbackListener.callbackQueryItems(fromHTTPRequest: "POST /auth/callback HTTP/1.1\r\n\r\n", callbackPath: "/auth/callback") == nil)
    }

    @Test func busyPreferredPortFallsBackToAnotherPortInsteadOfHanging() async throws {
        let occupyingListener = try await LoopbackOAuthCallbackListener.start(preferredPort: 0)
        defer { occupyingListener.stop() }
        let occupiedPort = UInt16(URLComponents(string: occupyingListener.redirectURI)!.port!)

        let secondListener = try await LoopbackOAuthCallbackListener.start(preferredPort: occupiedPort)
        defer { secondListener.stop() }
        let secondPort = UInt16(URLComponents(string: secondListener.redirectURI)!.port!)
        #expect(secondPort != occupiedPort)
    }

    @Test func listenerReceivesTheBrowserCallbackOnLoopback() async throws {
        let callbackListener = try await LoopbackOAuthCallbackListener.start(preferredPort: 0)
        defer { callbackListener.stop() }
        #expect(callbackListener.redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(callbackListener.redirectURI.hasSuffix("/auth/callback"))

        let callbackURL = URL(string: "\(callbackListener.redirectURI)?code=the-code&state=the-state")!
        async let browserVisit = URLSession.shared.data(from: callbackURL)
        let queryItems = try await callbackListener.waitForCallback(timeoutInSeconds: 10)
        let (pageData, pageResponse) = try await browserVisit

        #expect(queryItems.first(where: { $0.name == "code" })?.value == "the-code")
        #expect(queryItems.first(where: { $0.name == "state" })?.value == "the-state")
        #expect((pageResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pageData, as: UTF8.self).contains("go back to elfhub"))
    }

    @Test func strayCallbackWithAnotherStateDoesNotEndTheSignIn() async throws {
        let callbackListener = try await LoopbackOAuthCallbackListener.start(preferredPort: 0)
        defer { callbackListener.stop() }
        callbackListener.expectedState = "the-state"

        let strayURL = URL(string: "\(callbackListener.redirectURI)?code=someone-elses-code&state=another-state")!
        let (_, strayResponse) = try await URLSession.shared.data(from: strayURL)
        #expect((strayResponse as? HTTPURLResponse)?.statusCode == 400)

        let callbackURL = URL(string: "\(callbackListener.redirectURI)?code=the-code&state=the-state")!
        async let browserVisit = URLSession.shared.data(from: callbackURL)
        let queryItems = try await callbackListener.waitForCallback(timeoutInSeconds: 10)
        _ = try await browserVisit
        #expect(queryItems.first(where: { $0.name == "code" })?.value == "the-code")
    }

    @Test func aFailureIsReportedToALaterWaitInsteadOfACancellation() async throws {
        let callbackListener = try await LoopbackOAuthCallbackListener.start(preferredPort: 0)
        defer { callbackListener.stop() }
        await #expect(throws: ChatGPTPlanSignInError.signInTimedOut) {
            try await callbackListener.waitForCallback(timeoutInSeconds: 0.05)
        }
        await #expect(throws: ChatGPTPlanSignInError.signInTimedOut) {
            try await callbackListener.waitForCallback(timeoutInSeconds: 10)
        }
    }
}
