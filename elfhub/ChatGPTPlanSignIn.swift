//
//  ChatGPTPlanSignIn.swift
//  elfhub
//
//  The pure parts of "Continue with ChatGPT" (OpenAI's Sign in with ChatGPT,
//  ChatGPT plan usage for open-source local apps): PKCE, the authorize URL,
//  the browser-callback checks, token request bodies, the saved credentials,
//  and ID-token validation. Nothing here touches the network or the Keychain,
//  so every rule is unit-tested; `ChatGPTPlanAccount` does the I/O.
//
//  Protocol reference: developers.openai.com/siwc (token-sharing-open-source).
//  The app is a public OAuth client: no client secret, a loopback redirect on
//  127.0.0.1, and a client id that OpenAI issues on the first sign-in.
//

import CryptoKit
import Foundation
import Security

// MARK: - Constants

enum ChatGPTPlanOAuthConstants {
    /// OpenAI's OpenID Connect discovery document; endpoints and the JWKS
    /// location are read from it at sign-in.
    static let discoveryDocumentURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let expectedIssuer = "https://auth.openai.com"
    /// The API the access token is for. Sent on authorize, exchange and refresh.
    static let resource = "https://api.openai.com/v1"
    /// The first sign-in registers a new client; later sign-ins use the id it issued.
    static let firstRegistrationClientIdentifier = "dynamic_agent_client"
    /// What the user sees as this app's name on OpenAI's consent screen.
    static let agentNameHint = "elfhub"
    /// Identity scopes, then the scopes that let requests use the ChatGPT plan.
    static let requestedScopes = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    /// Without this granted scope the sign-in is valid but can't use the plan.
    static let planUsageScope = "chatgpt.tokens.use.direct"
    /// OpenAI only accepts this exact path; only the port may change.
    static let callbackPath = "/auth/callback"
    /// Tried first for the loopback listener; any free port works after it.
    static let preferredCallbackPort: UInt16 = 1455
    /// Where users review and limit what apps use from their plan.
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
}

// MARK: - Errors

enum ChatGPTPlanSignInError: LocalizedError, Equatable {
    case stateMismatch
    case accessDenied
    case authorizationFailed(String)
    case missingAuthorizationCode
    case missingIssuedClientIdentifier
    case unexpectedClientIdentifier
    case invalidIDToken(String)
    case differentAccount
    case tokenRequestFailed(statusCode: Int)
    /// OpenAI refused to swap the browser's code for tokens; `openAIReason`
    /// is its OAuth `error` and `error_description`, when it sent them.
    case codeExchangeRejected(statusCode: Int, openAIReason: String?)
    case invalidTokenResponse
    case discoveryFailed
    case callbackListenerFailed
    case signInTimedOut
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .stateMismatch: return "The sign-in reply didn't match this sign-in attempt. Please try again."
        case .accessDenied: return "ChatGPT sign-in was cancelled."
        case let .authorizationFailed(detail): return "ChatGPT sign-in failed: \(detail)"
        case .missingAuthorizationCode: return "ChatGPT sign-in didn't return a code. Please try again."
        case .missingIssuedClientIdentifier: return "ChatGPT didn't finish registering elfhub. Please try again."
        case .unexpectedClientIdentifier: return "ChatGPT returned a different app registration than expected. Please try again."
        case let .invalidIDToken(detail): return "ChatGPT's sign-in token couldn't be verified (\(detail))."
        case .differentAccount: return "That's a different ChatGPT account. Sign out first to switch accounts."
        case let .tokenRequestFailed(statusCode): return "ChatGPT sign-in failed (HTTP \(statusCode))."
        case let .codeExchangeRejected(statusCode, openAIReason):
            guard let openAIReason else { return "ChatGPT sign-in failed (HTTP \(statusCode))." }
            return "ChatGPT sign-in failed (HTTP \(statusCode): \(openAIReason))."
        case .invalidTokenResponse: return "ChatGPT sent an unreadable sign-in response."
        case .discoveryFailed: return "Couldn't reach ChatGPT's sign-in service."
        case .callbackListenerFailed: return "elfhub couldn't listen for the sign-in reply on this Mac."
        case .signInTimedOut: return "ChatGPT sign-in took too long. Please try again."
        case .signInRequired: return "Sign in with ChatGPT again in Settings, under Models."
        }
    }
}

// MARK: - Encoding helpers

enum ChatGPTPlanBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ base64URLString: String) -> Data? {
        var base64String = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - base64String.count % 4) % 4
        base64String += String(repeating: "=", count: paddingLength)
        return Data(base64Encoded: base64String)
    }
}

enum ChatGPTPlanRandomValue {
    /// A URL-safe random string from `byteCount` secure random bytes.
    static func makeURLSafeRandomString(byteCount: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &randomBytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes practically never fails; fall back to the
            // system generator rather than ever sending a predictable value.
            var systemGenerator = SystemRandomNumberGenerator()
            randomBytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &systemGenerator) }
        }
        return ChatGPTPlanBase64URL.encode(Data(randomBytes))
    }
}

/// application/x-www-form-urlencoded bodies for the token endpoint.
enum ChatGPTPlanFormEncoding {
    /// RFC 3986 unreserved characters; everything else is percent-encoded
    /// (form bodies must encode "+", "/", "=" in tokens).
    private static let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formBody(fromPairs pairs: [(String, String)]) -> Data {
        let encodedPairs = pairs.map { name, value in
            "\(percentEncoded(name))=\(percentEncoded(value))"
        }
        return Data(encodedPairs.joined(separator: "&").utf8)
    }

    static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }

    /// Reads a form body back into name → value (used by tests).
    static func decodedPairs(fromFormBody formBody: Data) -> [String: String] {
        var decodedValues: [String: String] = [:]
        for pair in String(decoding: formBody, as: UTF8.self).split(separator: "&") {
            let nameAndValue = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = nameAndValue.first?.removingPercentEncoding else { continue }
            let value = nameAndValue.count > 1 ? (nameAndValue[1].removingPercentEncoding ?? "") : ""
            decodedValues[name] = value
        }
        return decodedValues
    }
}

// MARK: - PKCE and host identity

struct ChatGPTPlanPKCE: Equatable {
    let codeVerifier: String
    let codeChallenge: String

    init(codeVerifier: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = Self.codeChallenge(forCodeVerifier: codeVerifier)
    }

    static func makeRandom() -> ChatGPTPlanPKCE {
        ChatGPTPlanPKCE(codeVerifier: ChatGPTPlanRandomValue.makeURLSafeRandomString(byteCount: 32))
    }

    /// S256: base64url(SHA-256(verifier)) without padding.
    static func codeChallenge(forCodeVerifier codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        return ChatGPTPlanBase64URL.encode(Data(digest))
    }
}

/// The stable, opaque id OpenAI uses to tell this Mac's installation apart
/// from the same user's other installations. Not a credential, and never the
/// user's email or account id.
enum ChatGPTPlanHostIdentifier {
    static func makeNew() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }
}

// MARK: - Discovery

struct ChatGPTPlanDiscoveryDocument: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let revocationEndpoint: URL?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
    }
}

// MARK: - One authorization attempt

/// Everything about one trip through the browser: fresh state, nonce and
/// PKCE, the exact redirect URI, and whether this registers a new client or
/// signs in to an existing registration.
struct ChatGPTPlanAuthorizationRequest {
    let authorizationEndpoint: URL
    let redirectURI: String
    let hostIdentifier: String
    /// The client id OpenAI issued at the first sign-in; nil registers a new one.
    let savedIssuedClientIdentifier: String?
    let idTokenHint: String?
    let loginHint: String?
    let state: String
    let nonce: String
    let pkce: ChatGPTPlanPKCE
    /// Shows OpenAI's consent screen again (OAuth `prompt=consent`). Only
    /// when the user chooses to allow plan use after declining it; an
    /// ordinary returning sign-in skips consent, so the earlier "no" would
    /// otherwise stick.
    var requestsConsentAgain = false

    var isFirstRegistration: Bool { savedIssuedClientIdentifier == nil }

    static func makeFresh(
        authorizationEndpoint: URL,
        redirectURI: String,
        hostIdentifier: String,
        savedIssuedClientIdentifier: String?,
        idTokenHint: String?,
        loginHint: String?,
        requestsConsentAgain: Bool = false
    ) -> ChatGPTPlanAuthorizationRequest {
        ChatGPTPlanAuthorizationRequest(
            authorizationEndpoint: authorizationEndpoint,
            redirectURI: redirectURI,
            hostIdentifier: hostIdentifier,
            savedIssuedClientIdentifier: savedIssuedClientIdentifier,
            idTokenHint: idTokenHint,
            loginHint: loginHint,
            state: ChatGPTPlanRandomValue.makeURLSafeRandomString(),
            nonce: ChatGPTPlanRandomValue.makeURLSafeRandomString(),
            pkce: ChatGPTPlanPKCE.makeRandom(),
            requestsConsentAgain: requestsConsentAgain
        )
    }

    /// The URL to open in the system browser.
    var authorizationURL: URL {
        var queryPairs: [(String, String)] = [
            ("client_id", savedIssuedClientIdentifier ?? ChatGPTPlanOAuthConstants.firstRegistrationClientIdentifier),
        ]
        if isFirstRegistration {
            // Only on the first registration; OpenAI ignores it afterwards.
            queryPairs.append(("agent_name_hint", ChatGPTPlanOAuthConstants.agentNameHint))
        }
        queryPairs.append(contentsOf: [
            ("ext_agent_host_id", hostIdentifier),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", ChatGPTPlanOAuthConstants.requestedScopes.joined(separator: " ")),
            ("resource", ChatGPTPlanOAuthConstants.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", pkce.codeChallenge),
        ])
        if !isFirstRegistration {
            if let idTokenHint, !idTokenHint.isEmpty { queryPairs.append(("id_token_hint", idTokenHint)) }
            if let loginHint, !loginHint.isEmpty { queryPairs.append(("login_hint", loginHint)) }
        }
        if requestsConsentAgain {
            queryPairs.append(("prompt", "consent"))
        }
        // Built by hand so every value is fully percent-encoded ("+" and "@"
        // included); URLComponents leaves those alone in query values.
        let encodedQuery = queryPairs
            .map { "\(ChatGPTPlanFormEncoding.percentEncoded($0.0))=\(ChatGPTPlanFormEncoding.percentEncoded($0.1))" }
            .joined(separator: "&")
        return URL(string: "\(authorizationEndpoint.absoluteString)?\(encodedQuery)")!
    }

    struct ValidatedCallback: Equatable {
        let authorizationCode: String
        /// The client id to use for the code exchange and from then on.
        let clientIdentifier: String
    }

    /// Checks the browser's return to the loopback callback: the state first
    /// (so a stray request can't cancel or complete the attempt), then any
    /// OAuth error, then the code and the client id.
    func validatedCallback(fromQueryItems queryItems: [URLQueryItem]) throws -> ValidatedCallback {
        func value(named name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        guard value(named: "state") == state else { throw ChatGPTPlanSignInError.stateMismatch }

        if let oauthError = value(named: "error") {
            if oauthError == "access_denied" { throw ChatGPTPlanSignInError.accessDenied }
            throw ChatGPTPlanSignInError.authorizationFailed(value(named: "error_description") ?? oauthError)
        }

        guard let authorizationCode = value(named: "code"), !authorizationCode.isEmpty else {
            throw ChatGPTPlanSignInError.missingAuthorizationCode
        }

        let callbackClientIdentifier = value(named: "client_id")
        if let savedIssuedClientIdentifier {
            // A returning sign-in may omit the client id, but must never
            // swap this registration for another one.
            if let callbackClientIdentifier, !callbackClientIdentifier.isEmpty,
               callbackClientIdentifier != savedIssuedClientIdentifier {
                throw ChatGPTPlanSignInError.unexpectedClientIdentifier
            }
            return ValidatedCallback(authorizationCode: authorizationCode, clientIdentifier: savedIssuedClientIdentifier)
        }

        guard let callbackClientIdentifier, !callbackClientIdentifier.isEmpty,
              callbackClientIdentifier != ChatGPTPlanOAuthConstants.firstRegistrationClientIdentifier else {
            throw ChatGPTPlanSignInError.missingIssuedClientIdentifier
        }
        return ValidatedCallback(authorizationCode: authorizationCode, clientIdentifier: callbackClientIdentifier)
    }

    /// The form body that exchanges the code for tokens. No client secret:
    /// PKCE proves this is the app that started the sign-in.
    func tokenExchangeFormBody(authorizationCode: String, clientIdentifier: String) -> Data {
        ChatGPTPlanFormEncoding.formBody(fromPairs: [
            ("grant_type", "authorization_code"),
            ("client_id", clientIdentifier),
            ("code", authorizationCode),
            ("code_verifier", pkce.codeVerifier),
            ("redirect_uri", redirectURI),
            ("resource", ChatGPTPlanOAuthConstants.resource),
        ])
    }
}

// MARK: - Token requests and responses

enum ChatGPTPlanTokenRequests {
    /// Renews the access token. `scope` is left out on purpose so the
    /// original grant is kept.
    static func refreshFormBody(refreshToken: String, clientIdentifier: String) -> Data {
        ChatGPTPlanFormEncoding.formBody(fromPairs: [
            ("grant_type", "refresh_token"),
            ("client_id", clientIdentifier),
            ("refresh_token", refreshToken),
            ("resource", ChatGPTPlanOAuthConstants.resource),
        ])
    }

    /// Ends the renewable session on sign-out.
    static func revocationFormBody(refreshToken: String, clientIdentifier: String) -> Data {
        ChatGPTPlanFormEncoding.formBody(fromPairs: [
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", clientIdentifier),
        ])
    }

    /// Refresh errors after which the saved tokens can never work again, so
    /// the user has to sign in again. Anything else (network, 5xx) keeps the
    /// tokens and is retried later.
    private static let terminalRefreshErrorCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    /// OpenAI's reason for refusing a token request, as "error: description"
    /// (OAuth error replies carry no tokens, so this is safe to show and log).
    static func oauthErrorReason(fromResponseBody responseBody: String) -> String? {
        guard let bodyData = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        var errorCode: String?
        var errorDescription = json["error_description"] as? String
        if let errorString = json["error"] as? String {
            errorCode = errorString
        } else if let errorObject = json["error"] as? [String: Any] {
            errorCode = errorObject["code"] as? String ?? errorObject["type"] as? String
            errorDescription = errorDescription ?? errorObject["message"] as? String
        }
        let reasonParts = [errorCode, errorDescription].compactMap { $0 }.filter { !$0.isEmpty }
        guard !reasonParts.isEmpty else { return nil }
        return String(reasonParts.joined(separator: ": ").prefix(200))
    }

    static func isTerminalRefreshError(responseBody: String) -> Bool {
        guard let bodyData = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return false
        }
        let errorCode: String?
        if let errorString = json["error"] as? String {
            errorCode = errorString
        } else if let errorObject = json["error"] as? [String: Any] {
            errorCode = errorObject["code"] as? String
        } else {
            errorCode = nil
        }
        guard let errorCode else { return false }
        return terminalRefreshErrorCodes.contains(errorCode)
    }
}

struct ChatGPTPlanTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresInSeconds: Int?
    /// Space-separated granted scopes.
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresInSeconds = "expires_in"
        case scope
    }

    var grantedScopes: [String]? {
        scope.map { $0.split(separator: " ").map(String.init) }
    }
}

// MARK: - Saved credentials

/// One signed-in ChatGPT account on this Mac, saved as JSON in the Keychain.
struct ChatGPTPlanCredentials: Codable, Equatable {
    var email: String?
    /// The verified ID-token subject: who this is.
    var subject: String
    /// The client id OpenAI issued to this installation for this account.
    var clientIdentifier: String
    var hostIdentifier: String
    /// Kept for `id_token_hint` on the next sign-in.
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiryDate: Date
    var grantedScopes: [String]
    var savedDate: Date

    /// Access tokens last an hour; renew this long before they run out so a
    /// turn never starts with a token that expires mid-reply.
    static let refreshMarginInSeconds: TimeInterval = 300

    var hasPlanUsageScope: Bool {
        grantedScopes.contains(ChatGPTPlanOAuthConstants.planUsageScope)
    }

    func needsRefresh(now: Date) -> Bool {
        now >= accessTokenExpiryDate.addingTimeInterval(-Self.refreshMarginInSeconds)
    }

    /// The access token, expiry, scopes and rotating refresh token are always
    /// replaced together after a refresh.
    func replacingTokens(with refreshResponse: ChatGPTPlanTokenResponse, now: Date) -> ChatGPTPlanCredentials {
        var refreshedCredentials = self
        refreshedCredentials.accessToken = refreshResponse.accessToken
        if let newRefreshToken = refreshResponse.refreshToken, !newRefreshToken.isEmpty {
            refreshedCredentials.refreshToken = newRefreshToken
        }
        if let newIDToken = refreshResponse.idToken, !newIDToken.isEmpty {
            refreshedCredentials.idToken = newIDToken
        }
        refreshedCredentials.accessTokenExpiryDate = now.addingTimeInterval(TimeInterval(refreshResponse.expiresInSeconds ?? 3600))
        if let newGrantedScopes = refreshResponse.grantedScopes {
            refreshedCredentials.grantedScopes = newGrantedScopes
        }
        refreshedCredentials.savedDate = now
        return refreshedCredentials
    }
}

/// What stays after signing out, so the next sign-in reuses this
/// installation's registration instead of creating another app in the
/// user's ChatGPT settings.
struct ChatGPTPlanRegistration: Codable, Equatable {
    var issuedClientIdentifier: String
    var subject: String
    var email: String?
}

// MARK: - ID token validation

struct ChatGPTPlanIDTokenClaims: Equatable {
    let subject: String
    let email: String?
}

enum ChatGPTPlanIDTokenValidator {
    /// Allowed difference between this Mac's clock and OpenAI's.
    static let allowedClockSkewInSeconds: TimeInterval = 120

    /// Verifies the ID token's RS256 signature against the JWKS, then its
    /// issuer, audience (the issued client id), expiry and nonce.
    static func validatedClaims(
        idToken: String,
        jwksData: Data,
        expectedIssuer: String,
        expectedAudience: String,
        expectedNonce: String,
        now: Date
    ) throws -> ChatGPTPlanIDTokenClaims {
        let tokenParts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard tokenParts.count == 3,
              let headerData = ChatGPTPlanBase64URL.decode(tokenParts[0]),
              let payloadData = ChatGPTPlanBase64URL.decode(tokenParts[1]),
              let signatureData = ChatGPTPlanBase64URL.decode(tokenParts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ChatGPTPlanSignInError.invalidIDToken("malformed")
        }

        guard header["alg"] as? String == "RS256" else {
            throw ChatGPTPlanSignInError.invalidIDToken("unsupported algorithm")
        }
        let publicKey = try signingKey(fromJWKSData: jwksData, keyIdentifier: header["kid"] as? String)
        let signingInput = Data("\(tokenParts[0]).\(tokenParts[1])".utf8)
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signatureData as CFData, nil) else {
            throw ChatGPTPlanSignInError.invalidIDToken("bad signature")
        }

        guard payload["iss"] as? String == expectedIssuer else {
            throw ChatGPTPlanSignInError.invalidIDToken("wrong issuer")
        }
        let audiences: [String]
        if let singleAudience = payload["aud"] as? String {
            audiences = [singleAudience]
        } else {
            audiences = payload["aud"] as? [String] ?? []
        }
        guard audiences.contains(expectedAudience) else {
            throw ChatGPTPlanSignInError.invalidIDToken("wrong audience")
        }
        guard let expirySeconds = (payload["exp"] as? NSNumber)?.doubleValue,
              now.timeIntervalSince1970 < expirySeconds + allowedClockSkewInSeconds else {
            throw ChatGPTPlanSignInError.invalidIDToken("expired")
        }
        guard payload["nonce"] as? String == expectedNonce else {
            throw ChatGPTPlanSignInError.invalidIDToken("wrong nonce")
        }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else {
            throw ChatGPTPlanSignInError.invalidIDToken("no subject")
        }
        return ChatGPTPlanIDTokenClaims(subject: subject, email: payload["email"] as? String)
    }

    /// The RSA key from the JWKS whose `kid` matches the token header (or
    /// the only RSA key when the header names none).
    private static func signingKey(fromJWKSData jwksData: Data, keyIdentifier: String?) throws -> SecKey {
        guard let jwks = try? JSONSerialization.jsonObject(with: jwksData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]] else {
            throw ChatGPTPlanSignInError.invalidIDToken("unreadable key set")
        }
        let rsaKeys = keys.filter { $0["kty"] as? String == "RSA" }
        let matchingKey: [String: Any]?
        if let keyIdentifier {
            matchingKey = rsaKeys.first(where: { $0["kid"] as? String == keyIdentifier })
        } else {
            matchingKey = rsaKeys.count == 1 ? rsaKeys.first : nil
        }
        guard let matchingKey,
              let modulusString = matchingKey["n"] as? String,
              let exponentString = matchingKey["e"] as? String,
              let modulus = ChatGPTPlanBase64URL.decode(modulusString),
              let exponent = ChatGPTPlanBase64URL.decode(exponentString),
              let publicKey = rsaPublicKey(modulus: modulus, exponent: exponent) else {
            throw ChatGPTPlanSignInError.invalidIDToken("unknown signing key")
        }
        return publicKey
    }

    /// Builds a SecKey from a JWK's modulus and exponent. Security.framework
    /// takes RSA public keys as PKCS#1 DER: SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let publicKeyDER = derSequence(of: [derInteger(modulus), derInteger(exponent)])
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(publicKeyDER as CFData, keyAttributes as CFDictionary, nil)
    }

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var lengthBytes: [UInt8] = []
        var remainingLength = length
        while remainingLength > 0 {
            lengthBytes.insert(UInt8(remainingLength & 0xFF), at: 0)
            remainingLength >>= 8
        }
        return [0x80 | UInt8(lengthBytes.count)] + lengthBytes
    }

    /// A positive DER INTEGER: no extra leading zeros, plus one zero byte when
    /// the top bit is set so it isn't read as negative.
    private static func derInteger(_ unsignedBigEndianBytes: Data) -> [UInt8] {
        var integerBytes = [UInt8](unsignedBigEndianBytes)
        while integerBytes.count > 1, integerBytes.first == 0 { integerBytes.removeFirst() }
        if let firstByte = integerBytes.first, firstByte & 0x80 != 0 { integerBytes.insert(0, at: 0) }
        return [0x02] + derLength(integerBytes.count) + integerBytes
    }

    private static func derSequence(of elements: [[UInt8]]) -> Data {
        let contents = elements.flatMap { $0 }
        return Data([0x30] + derLength(contents.count) + contents)
    }
}
