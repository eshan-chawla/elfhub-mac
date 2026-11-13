//
//  ChatGPTPlanSignInTests.swift
//  elfhubTests
//
//  "Continue with ChatGPT" sign-in, without the network: PKCE, the
//  authorize URL for a first registration and a returning sign-in, the
//  browser callback checks, token form bodies, the saved credentials and
//  their refresh timing, and ID-token signature + claim validation against
//  a JWKS made from a throwaway RSA key.
//

import Foundation
import Security
import Testing
@testable import elfhub

struct ChatGPTPlanSignInTests {

    // MARK: - PKCE

    @Test func pkceChallengeMatchesTheRFC7636Example() {
        let codeChallenge = ChatGPTPlanPKCE.codeChallenge(forCodeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(codeChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomPKCEVerifierIsURLSafeAndLongEnough() {
        let pkce = ChatGPTPlanPKCE.makeRandom()
        #expect(pkce.codeVerifier.count >= 43)
        #expect(!pkce.codeVerifier.contains("="))
        #expect(!pkce.codeVerifier.contains("+"))
        #expect(!pkce.codeVerifier.contains("/"))
        #expect(pkce.codeChallenge == ChatGPTPlanPKCE.codeChallenge(forCodeVerifier: pkce.codeVerifier))
        #expect(ChatGPTPlanPKCE.makeRandom().codeVerifier != pkce.codeVerifier)
    }

    @Test func hostIdentifierIsAnOpaqueUUIDURN() {
        let hostIdentifier = ChatGPTPlanHostIdentifier.makeNew()
        #expect(hostIdentifier.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(hostIdentifier.dropFirst("urn:uuid:".count))) != nil)
    }

    // MARK: - Authorize URL

    private func authorizationRequest(
        savedIssuedClientIdentifier: String? = nil,
        idTokenHint: String? = nil,
        loginHint: String? = nil
    ) -> ChatGPTPlanAuthorizationRequest {
        ChatGPTPlanAuthorizationRequest(
            authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            redirectURI: "http://127.0.0.1:1455/auth/callback",
            hostIdentifier: "urn:uuid:11111111-2222-3333-4444-555555555555",
            savedIssuedClientIdentifier: savedIssuedClientIdentifier,
            idTokenHint: idTokenHint,
            loginHint: loginHint,
            state: "state-value",
            nonce: "nonce-value",
            pkce: ChatGPTPlanPKCE(codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        )
    }

    private func queryValues(of url: URL) -> [String: String] {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func firstRegistrationAsksForDynamicClientAndPlanScopes() {
        let authorizationURL = authorizationRequest().authorizationURL
        let queryValues = queryValues(of: authorizationURL)
        #expect(authorizationURL.host == "auth.openai.com")
        #expect(queryValues["client_id"] == "dynamic_agent_client")
        #expect(queryValues["agent_name_hint"] == "elfhub")
        #expect(queryValues["ext_agent_host_id"] == "urn:uuid:11111111-2222-3333-4444-555555555555")
        #expect(queryValues["response_type"] == "code")
        #expect(queryValues["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(queryValues["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(queryValues["resource"] == "https://api.openai.com/v1")
        #expect(queryValues["state"] == "state-value")
        #expect(queryValues["nonce"] == "nonce-value")
        #expect(queryValues["code_challenge_method"] == "S256")
        #expect(queryValues["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(queryValues["id_token_hint"] == nil)
        #expect(queryValues["login_hint"] == nil)
    }

    @Test func returningSignInReusesTheIssuedClientAndSendsHints() {
        let authorizationURL = authorizationRequest(
            savedIssuedClientIdentifier: "oaiapp_saved",
            idTokenHint: "old.id.token",
            loginHint: "person@example.com"
        ).authorizationURL
        let queryValues = queryValues(of: authorizationURL)
        #expect(queryValues["client_id"] == "oaiapp_saved")
        #expect(queryValues["agent_name_hint"] == nil)
        #expect(queryValues["ext_agent_host_id"] == "urn:uuid:11111111-2222-3333-4444-555555555555")
        #expect(queryValues["id_token_hint"] == "old.id.token")
        #expect(queryValues["login_hint"] == "person@example.com")
    }

    @Test func askingForPlanConsentAgainAddsPromptConsentOnlyThen() {
        var consentRequest = authorizationRequest(savedIssuedClientIdentifier: "oaiapp_saved")
        consentRequest.requestsConsentAgain = true
        #expect(queryValues(of: consentRequest.authorizationURL)["prompt"] == "consent")
        #expect(queryValues(of: consentRequest.authorizationURL)["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        #expect(queryValues(of: authorizationRequest(savedIssuedClientIdentifier: "oaiapp_saved").authorizationURL)["prompt"] == nil)
    }

    @Test func authorizeURLPercentEncodesPlusAndAtSigns() {
        let authorizationURL = authorizationRequest(savedIssuedClientIdentifier: "oaiapp_saved", loginHint: "a+b@example.com")
            .authorizationURL.absoluteString
        #expect(authorizationURL.contains("login_hint=a%2Bb%40example.com"))
    }

    // MARK: - Callback

    private func queryItems(_ pairs: [String: String]) -> [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    @Test func firstRegistrationCallbackReturnsCodeAndIssuedClient() throws {
        let callback = try authorizationRequest().validatedCallback(fromQueryItems: queryItems([
            "code": "the-code", "state": "state-value", "client_id": "oaiapp_new",
        ]))
        #expect(callback.authorizationCode == "the-code")
        #expect(callback.clientIdentifier == "oaiapp_new")
    }

    @Test func callbackWithWrongStateIsRejectedBeforeAnythingElse() {
        #expect(throws: ChatGPTPlanSignInError.stateMismatch) {
            try authorizationRequest().validatedCallback(fromQueryItems: queryItems([
                "code": "the-code", "state": "someone-else", "client_id": "oaiapp_new",
            ]))
        }
        #expect(throws: ChatGPTPlanSignInError.stateMismatch) {
            try authorizationRequest().validatedCallback(fromQueryItems: queryItems(["error": "access_denied"]))
        }
    }

    @Test func declinedConsentStopsTheSignIn() {
        #expect(throws: ChatGPTPlanSignInError.accessDenied) {
            try authorizationRequest().validatedCallback(fromQueryItems: queryItems([
                "error": "access_denied", "state": "state-value",
            ]))
        }
    }

    @Test func firstRegistrationWithoutAnIssuedClientIsIncomplete() {
        #expect(throws: ChatGPTPlanSignInError.missingIssuedClientIdentifier) {
            try authorizationRequest().validatedCallback(fromQueryItems: queryItems([
                "code": "the-code", "state": "state-value",
            ]))
        }
        #expect(throws: ChatGPTPlanSignInError.missingIssuedClientIdentifier) {
            try authorizationRequest().validatedCallback(fromQueryItems: queryItems([
                "code": "the-code", "state": "state-value", "client_id": "dynamic_agent_client",
            ]))
        }
    }

    @Test func returningSignInKeepsTheSavedClientAndRejectsAnother() throws {
        let returningRequest = authorizationRequest(savedIssuedClientIdentifier: "oaiapp_saved")
        let callbackWithoutClient = try returningRequest.validatedCallback(fromQueryItems: queryItems([
            "code": "the-code", "state": "state-value",
        ]))
        #expect(callbackWithoutClient.clientIdentifier == "oaiapp_saved")
        #expect(throws: ChatGPTPlanSignInError.unexpectedClientIdentifier) {
            try returningRequest.validatedCallback(fromQueryItems: queryItems([
                "code": "the-code", "state": "state-value", "client_id": "oaiapp_other",
            ]))
        }
    }

    // MARK: - Token form bodies

    @Test func codeExchangeBodyCarriesVerifierRedirectAndResource() {
        let formBody = authorizationRequest().tokenExchangeFormBody(authorizationCode: "the-code", clientIdentifier: "oaiapp_new")
        let formValues = ChatGPTPlanFormEncoding.decodedPairs(fromFormBody: formBody)
        #expect(formValues["grant_type"] == "authorization_code")
        #expect(formValues["client_id"] == "oaiapp_new")
        #expect(formValues["code"] == "the-code")
        #expect(formValues["code_verifier"] == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(formValues["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(formValues["resource"] == "https://api.openai.com/v1")
    }

    @Test func refreshBodyUsesTheIssuedClientAndNoScope() {
        let formValues = ChatGPTPlanFormEncoding.decodedPairs(
            fromFormBody: ChatGPTPlanTokenRequests.refreshFormBody(refreshToken: "refresh/+=", clientIdentifier: "oaiapp_saved")
        )
        #expect(formValues["grant_type"] == "refresh_token")
        #expect(formValues["client_id"] == "oaiapp_saved")
        #expect(formValues["refresh_token"] == "refresh/+=")
        #expect(formValues["resource"] == "https://api.openai.com/v1")
        #expect(formValues["scope"] == nil)
    }

    @Test func revocationBodyNamesTheRefreshToken() {
        let formValues = ChatGPTPlanFormEncoding.decodedPairs(
            fromFormBody: ChatGPTPlanTokenRequests.revocationFormBody(refreshToken: "refresh", clientIdentifier: "oaiapp_saved")
        )
        #expect(formValues["token"] == "refresh")
        #expect(formValues["token_type_hint"] == "refresh_token")
        #expect(formValues["client_id"] == "oaiapp_saved")
    }

    @Test func terminalRefreshErrorsMeanSignInAgain() {
        #expect(ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: #"{"error":"invalid_grant"}"#))
        #expect(ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: #"{"error":"refresh_token_reused"}"#))
        #expect(ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: #"{"error":{"code":"refresh_token_expired"}}"#))
        #expect(!ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: #"{"error":"server_error"}"#))
        #expect(!ChatGPTPlanTokenRequests.isTerminalRefreshError(responseBody: "<html>bad gateway</html>"))
    }

    // MARK: - Credentials

    private let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func sampleCredentials() -> ChatGPTPlanCredentials {
        ChatGPTPlanCredentials(
            email: "person@example.com",
            subject: "user-subject",
            clientIdentifier: "oaiapp_saved",
            hostIdentifier: "urn:uuid:11111111-2222-3333-4444-555555555555",
            idToken: "id.token.value",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            accessTokenExpiryDate: referenceDate.addingTimeInterval(3600),
            grantedScopes: ["openid", "email", "chatgpt.tokens.use.direct"],
            savedDate: referenceDate
        )
    }

    @Test func credentialsRoundTripAndKnowThePlanScope() throws {
        let credentials = sampleCredentials()
        let decoded = try JSONDecoder().decode(ChatGPTPlanCredentials.self, from: JSONEncoder().encode(credentials))
        #expect(decoded == credentials)
        #expect(credentials.hasPlanUsageScope)
        var withoutPlanScope = credentials
        withoutPlanScope.grantedScopes = ["openid", "email"]
        #expect(!withoutPlanScope.hasPlanUsageScope)
    }

    @Test func refreshIsDueFiveMinutesBeforeExpiry() {
        let credentials = sampleCredentials()
        #expect(!credentials.needsRefresh(now: referenceDate))
        #expect(!credentials.needsRefresh(now: referenceDate.addingTimeInterval(3600 - 301)))
        #expect(credentials.needsRefresh(now: referenceDate.addingTimeInterval(3600 - 300)))
        #expect(credentials.needsRefresh(now: referenceDate.addingTimeInterval(4000)))
    }

    @Test func refreshReplacesTokensExpiryAndScopesTogether() throws {
        let refreshResponse = try JSONDecoder().decode(
            ChatGPTPlanTokenResponse.self,
            from: Data(#"{"access_token":"access-2","refresh_token":"refresh-2","token_type":"Bearer","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct"}"#.utf8)
        )
        let later = referenceDate.addingTimeInterval(3500)
        let refreshed = sampleCredentials().replacingTokens(with: refreshResponse, now: later)
        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-2")
        #expect(refreshed.accessTokenExpiryDate == later.addingTimeInterval(3600))
        #expect(refreshed.grantedScopes == ["openid", "chatgpt.tokens.use.direct"])
        #expect(refreshed.idToken == "id.token.value")
        #expect(refreshed.clientIdentifier == "oaiapp_saved")
        #expect(refreshed.savedDate == later)
    }

    @Test func refreshWithoutNewRefreshTokenOrScopeKeepsTheOldOnes() throws {
        let refreshResponse = try JSONDecoder().decode(
            ChatGPTPlanTokenResponse.self,
            from: Data(#"{"access_token":"access-2","expires_in":3600}"#.utf8)
        )
        let refreshed = sampleCredentials().replacingTokens(with: refreshResponse, now: referenceDate)
        #expect(refreshed.refreshToken == "refresh-1")
        #expect(refreshed.grantedScopes == ["openid", "email", "chatgpt.tokens.use.direct"])
    }

    // MARK: - ID token

    private func validClaims(expiry: Date? = nil) -> [String: Any] {
        [
            "iss": "https://auth.openai.com",
            "aud": "oaiapp_new",
            "sub": "user-subject",
            "email": "person@example.com",
            "nonce": "nonce-value",
            "exp": Int((expiry ?? referenceDate.addingTimeInterval(600)).timeIntervalSince1970),
            "iat": Int(referenceDate.timeIntervalSince1970),
        ]
    }

    private func validate(_ idToken: String, jwksData: Data, nonce: String = "nonce-value") throws -> ChatGPTPlanIDTokenClaims {
        try ChatGPTPlanIDTokenValidator.validatedClaims(
            idToken: idToken,
            jwksData: jwksData,
            expectedIssuer: "https://auth.openai.com",
            expectedAudience: "oaiapp_new",
            expectedNonce: nonce,
            now: referenceDate
        )
    }

    @Test func validIDTokenGivesTheVerifiedIdentity() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        let claims = try validate(try signingKey.signedToken(claims: validClaims()), jwksData: signingKey.jwksData)
        #expect(claims.subject == "user-subject")
        #expect(claims.email == "person@example.com")
    }

    @Test func idTokenAudienceMayBeAList() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        var claims = validClaims()
        claims["aud"] = ["something-else", "oaiapp_new"]
        #expect(try validate(try signingKey.signedToken(claims: claims), jwksData: signingKey.jwksData).subject == "user-subject")
    }

    @Test func idTokenSignedByAnotherKeyIsRejected() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        let otherKey = try ChatGPTPlanTestSigningKey()
        let idToken = try otherKey.signedToken(claims: validClaims())
        #expect(throws: ChatGPTPlanSignInError.self) { try validate(idToken, jwksData: signingKey.jwksData) }
    }

    @Test func idTokenWithTamperedClaimsIsRejected() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        let idTokenParts = try signingKey.signedToken(claims: validClaims()).split(separator: ".").map(String.init)
        var tamperedClaims = validClaims()
        tamperedClaims["sub"] = "attacker"
        let tamperedPayload = ChatGPTPlanBase64URL.encode(try JSONSerialization.data(withJSONObject: tamperedClaims))
        let tamperedToken = [idTokenParts[0], tamperedPayload, idTokenParts[2]].joined(separator: ".")
        #expect(throws: ChatGPTPlanSignInError.self) { try validate(tamperedToken, jwksData: signingKey.jwksData) }
    }

    @Test func idTokenWithWrongIssuerAudienceNonceOrExpiryIsRejected() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        for (claimName, badValue) in [("iss", "https://evil.example.com"), ("aud", "oaiapp_other"), ("nonce", "other-nonce")] {
            var claims = validClaims()
            claims[claimName] = badValue
            let idToken = try signingKey.signedToken(claims: claims)
            #expect(throws: ChatGPTPlanSignInError.self) { try validate(idToken, jwksData: signingKey.jwksData) }
        }
        let expiredToken = try signingKey.signedToken(claims: validClaims(expiry: referenceDate.addingTimeInterval(-120)))
        #expect(throws: ChatGPTPlanSignInError.self) { try validate(expiredToken, jwksData: signingKey.jwksData) }
    }

    @Test func idTokenWithUnsupportedAlgorithmIsRejected() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        let idToken = try signingKey.signedToken(claims: validClaims(), algorithm: "none")
        #expect(throws: ChatGPTPlanSignInError.self) { try validate(idToken, jwksData: signingKey.jwksData) }
    }

    @Test func idTokenNamingAnUnknownKeyIsRejected() throws {
        let signingKey = try ChatGPTPlanTestSigningKey()
        let idToken = try signingKey.signedToken(claims: validClaims(), keyIdentifier: "rotated-away")
        #expect(throws: ChatGPTPlanSignInError.self) { try validate(idToken, jwksData: signingKey.jwksData) }
    }

    // MARK: - Discovery

    @Test func discoveryDocumentGivesTheEndpoints() throws {
        let discoveryDocument = try JSONDecoder().decode(ChatGPTPlanDiscoveryDocument.self, from: Data(#"""
        {"issuer":"https://auth.openai.com",
         "authorization_endpoint":"https://auth.openai.com/api/accounts/authorize",
         "token_endpoint":"https://auth.openai.com/api/accounts/oauth/token",
         "jwks_uri":"https://auth.openai.com/.well-known/jwks.json",
         "revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke",
         "extra":"ignored"}
        """#.utf8))
        #expect(discoveryDocument.issuer == "https://auth.openai.com")
        #expect(discoveryDocument.tokenEndpoint.absoluteString == "https://auth.openai.com/api/accounts/oauth/token")
        #expect(discoveryDocument.revocationEndpoint?.absoluteString == "https://auth.openai.com/api/accounts/oauth/revoke")
    }
}
