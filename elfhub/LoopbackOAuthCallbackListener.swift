//
//  LoopbackOAuthCallbackListener.swift
//  elfhub
//
//  A tiny one-shot HTTP server on 127.0.0.1 that receives the browser's
//  return from "Continue with ChatGPT". OpenAI only redirects public apps to
//  an http loopback address, so elfhub listens there for the few minutes a
//  sign-in takes, answers the browser with a "you can go back" page, and
//  stops. It never listens on any other interface and is never running
//  outside a sign-in.
//
//  Network.framework callbacks are delivered on the main queue: the app's
//  default isolation is the main actor, and a sign-in callback is one request,
//  so there is nothing to gain from a background queue.
//

import Foundation
import Network

final class LoopbackOAuthCallbackListener {

    /// The redirect URI to send in the authorize request and the code exchange.
    let redirectURI: String
    /// The `state` of the sign-in in progress, set before the browser opens.
    /// A callback with any other state (a stale tab, or another program
    /// probing the port) gets an error page and doesn't end the sign-in.
    var expectedState: String?

    private let listener: NWListener
    private var callbackContinuation: CheckedContinuation<[URLQueryItem], Error>?
    /// How the listener ended (the callback, a failure or the timeout),
    /// kept so a wait that starts afterwards gets the same outcome.
    private var finishedResult: Result<[URLQueryItem], Error>?

    private init(listener: NWListener, port: UInt16, callbackPath: String) {
        self.listener = listener
        self.redirectURI = "http://127.0.0.1:\(port)\(callbackPath)"
    }

    /// Starts listening on 127.0.0.1, on `preferredPort` when it's free and
    /// otherwise on any free port (OpenAI allows the port to change).
    static func start(
        preferredPort: UInt16 = ChatGPTPlanOAuthConstants.preferredCallbackPort,
        callbackPath: String = ChatGPTPlanOAuthConstants.callbackPath
    ) async throws -> LoopbackOAuthCallbackListener {
        if let preferredPortListener = try? await startListener(onPort: preferredPort, callbackPath: callbackPath) {
            return preferredPortListener
        }
        return try await startListener(onPort: 0, callbackPath: callbackPath)
    }

    private static func startListener(onPort requestedPort: UInt16, callbackPath: String) async throws -> LoopbackOAuthCallbackListener {
        let parameters = NWParameters.tcp
        // Bind to the loopback address only: nothing on the network can reach it.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )
        let listener = try NWListener(using: parameters)

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { readyContinuation in
            var hasResumed = false
            listener.stateUpdateHandler = { listenerState in
                guard !hasResumed else { return }
                switch listenerState {
                case .ready:
                    hasResumed = true
                    readyContinuation.resume(returning: listener.port?.rawValue ?? requestedPort)
                case .failed, .cancelled, .waiting:
                    // `.waiting` (for example the port is taken) would
                    // otherwise wait forever; fail so another port is tried.
                    hasResumed = true
                    listener.cancel()
                    readyContinuation.resume(throwing: ChatGPTPlanSignInError.callbackListenerFailed)
                default:
                    break
                }
            }
            // Never wait more than a few seconds for the listener to start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !hasResumed else { return }
                hasResumed = true
                listener.cancel()
                readyContinuation.resume(throwing: ChatGPTPlanSignInError.callbackListenerFailed)
            }
            // Connections are refused until the handler below is installed,
            // so accept nothing yet; the instance sets the real handler.
            listener.newConnectionHandler = { connection in connection.cancel() }
            listener.start(queue: .main)
        }

        let callbackListener = LoopbackOAuthCallbackListener(listener: listener, port: boundPort, callbackPath: callbackPath)
        callbackListener.acceptConnections(callbackPath: callbackPath)
        return callbackListener
    }

    private func acceptConnections(callbackPath: String) {
        listener.stateUpdateHandler = { [weak self] listenerState in
            if case .failed = listenerState {
                self?.finish(with: .failure(ChatGPTPlanSignInError.callbackListenerFailed))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, callbackPath: callbackPath)
        }
    }

    /// Waits for the browser to come back with the authorization result.
    func waitForCallback(timeoutInSeconds: Double = 300) async throws -> [URLQueryItem] {
        if let finishedResult { return try finishedResult.get() }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutInSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(with: .failure(ChatGPTPlanSignInError.signInTimedOut))
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let finishedResult {
                    continuation.resume(with: finishedResult)
                    return
                }
                callbackContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(with: .failure(CancellationError()))
            }
        }
    }

    /// Stops listening. Safe to call more than once.
    func stop() {
        listener.cancel()
    }

    private func finish(with result: Result<[URLQueryItem], Error>) {
        // The first outcome wins; a late timeout or cancellation can't
        // replace a callback that already arrived.
        guard finishedResult == nil else { return }
        finishedResult = result
        stop()
        guard let continuation = callbackContinuation else { return }
        callbackContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - HTTP

    private func handle(_ connection: NWConnection, callbackPath: String) {
        connection.start(queue: .main)
        // A browser's GET fits in one read; the callback carries no body.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] receivedData, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let requestText = receivedData.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let queryItems = Self.callbackQueryItems(fromHTTPRequest: requestText, callbackPath: callbackPath) else {
                // Anything else (a favicon request, a stray probe) gets a 404
                // and doesn't end the sign-in.
                Self.respond(on: connection, statusLine: "404 Not Found", htmlBody: "Not found")
                return
            }
            if let expectedState = self.expectedState,
               queryItems.first(where: { $0.name == "state" })?.value != expectedState {
                Self.respond(on: connection, statusLine: "400 Bad Request", htmlBody: Self.unexpectedSignInPage)
                return
            }
            Self.respond(on: connection, statusLine: "200 OK", htmlBody: Self.returnToAppPage)
            self.finish(with: .success(queryItems))
        }
    }

    /// The query of a `GET <callbackPath>?…` request line, or nil for any
    /// other request.
    static func callbackQueryItems(fromHTTPRequest requestText: String, callbackPath: String) -> [URLQueryItem]? {
        guard let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first ?? requestText.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        let requestLineParts = requestLine.split(separator: " ")
        guard requestLineParts.count >= 2, requestLineParts[0] == "GET",
              let requestTarget = URLComponents(string: String(requestLineParts[1])),
              requestTarget.path == callbackPath else {
            return nil
        }
        return requestTarget.queryItems ?? []
    }

    private static func respond(on connection: NWConnection, statusLine: String, htmlBody: String) {
        let bodyData = Data(htmlBody.utf8)
        let headers = [
            "HTTP/1.1 \(statusLine)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(headers.utf8) + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let returnToAppPage = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>elfhub</title>
    <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;height:90vh;margin:0;color:#222;background:#fafafa}
    @media (prefers-color-scheme: dark){body{color:#eee;background:#1e1e1e}}</style></head>
    <body><p>You can close this tab and go back to elfhub.</p></body></html>
    """

    private static let unexpectedSignInPage = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>elfhub</title></head>
    <body><p>This sign-in link doesn't belong to the sign-in elfhub is waiting for. Start again from elfhub.</p></body></html>
    """
}
