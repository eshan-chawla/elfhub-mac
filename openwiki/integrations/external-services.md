---
type: integration-boundary
title: External Services and Network Boundary
description: Every network destination elfhub can reach (cloud model, speech and voice APIs called with the user's own key, plus model servers on localhost), how each one is authenticated, and what data leaves the Mac.
tags: [integrations, network, anthropic, openai-compatible, gemini, assemblyai, elevenlabs, ollama, privacy, security]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-0177b3dee36893e98a6c2ced
    resource: repo://elfhub/AssemblyAIStreamingTranscriptionProvider.swift
  - id: openwiki-source-421db9e564db79570d0c1838
    resource: repo://elfhub/ClaudeAPI.swift
  - id: openwiki-source-59f28e5e4d4cffcc857b71f4
    resource: repo://elfhub/ElevenLabsTTSClient.swift
  - id: openwiki-source-4af303bbae9abdc4edce5856
    resource: repo://elfhub/GeminiLanguageModelProvider.swift
  - id: openwiki-source-16facb9fcf8a514f9c44279d
    resource: repo://elfhub/OpenAIAudioTranscriptionProvider.swift
  - id: openwiki-source-b7fbc2dc97a752daa61db1cf
    resource: repo://elfhub/OpenAICompatibleLanguageModelProvider.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# External Services and Network Boundary

elfhub has no backend. Every request goes straight from the app to a service the user picked, using their key from the Keychain, or to a server on their own Mac. "Get a key" and "Get Ollama" links open in the browser; the app never fetches them itself.

## Language models

| Provider | Endpoint | Auth | Notes |
|---|---|---|---|
| Anthropic (`ClaudeAPI`) | `<base>/v1/messages` (default `https://api.anthropic.com`), SSE | `x-api-key` + `anthropic-version: 2023-06-01` | Sends `fallbacks: "default"` with the `server-side-fallback-2026-07-01` beta, but only direct to `*.anthropic.com` and only for models that support it. Warms up the TLS connection once. 120 s request / 300 s resource timeouts. |
| OpenAI-compatible | `<base>/chat/completions`, SSE | `Authorization: Bearer <key>`, omitted when there is no key | One adapter for OpenAI, OpenRouter, Mistral, xAI, Groq, DeepSeek, Together, Ollama, LM Studio, llama.cpp and vLLM. Streamed tool calls are reassembled by `OpenAIStreamAccumulator`. |
| Gemini | `<base>/models/<model>:streamGenerateContent?alt=sse` | `x-goog-api-key` | Uses Gemini's own request and response shape: system instruction, `contents`, function declarations and calls. |

Sources: `elfhub/ClaudeAPI.swift:17-96`, `:140-150`, `elfhub/OpenAICompatibleLanguageModelProvider.swift:27-54`, `elfhub/GeminiLanguageModelProvider.swift:33-54`.

What a turn sends:

- the system prompt;
- up to 10 earlier exchanges, as text;
- the user's words, plus a note about their drawing if they drew;
- for a vision-capable configuration only, one JPEG of the display under the cursor, sized to the model's limits.

Text-only configurations get no image.

## Speech-to-text

| Choice | Destination | Auth |
|---|---|---|
| Apple on-device (default) | None. SpeechAnalyzer or SFSpeechRecognizer runs on the Mac. | — |
| AssemblyAI | `wss://streaming.assemblyai.com/v3/ws` (streaming) | `Authorization: <key>` on the websocket request |
| OpenAI-compatible Whisper | `<base>/audio/transcriptions` (upload of the WAV clip). Presets: OpenAI, Groq, local faster-whisper on `localhost:8000`. | `Authorization: Bearer <key>`, optional for local servers |

Sources: `elfhub/AssemblyAIStreamingTranscriptionProvider.swift:96`, `:141-144`, `elfhub/OpenAIAudioTranscriptionProvider.swift:28`, `:195`.

The AssemblyAI provider shares one long-lived `URLSession` across sessions. Creating and invalidating a session per dictation corrupts the connection pool and leads to "Socket is not connected" errors.

## Text-to-speech

| Choice | Destination | Auth |
|---|---|---|
| Apple on-device (default) | None (`AVSpeechSynthesizer`) | — |
| ElevenLabs | `https://api.elevenlabs.io/v1/text-to-speech/<voice>?output_format=mp3_44100_128`, one request per sentence | `xi-api-key` |
| OpenAI-compatible | `<base>/audio/speech`. Presets: OpenAI, local Kokoro on `localhost:8880`. | `Authorization: Bearer <key>`, optional for local servers |

Sources: `elfhub/ElevenLabsTTSClient.swift:53-58`, `:101-109`. Only the reply's speakable sentences are sent; tags are stripped first.

## On this Mac

- **Ollama.** `OnDeviceModelAssistant` calls only `http://localhost:11434` (`/api/version`, `/api/tags`, `/api/pull`, `/api/show`, `/api/delete`). Ollama itself downloads the models (`elfhub/OnDeviceModelAssistant.swift:235-237`).
- **Other local servers.** Any base URL whose host is `localhost`, `127.0.0.1`, `::1` or `*.local` counts as local and needs no key. With a local model, prompts and screenshots never reach a cloud API (`elfhub/ProviderConfiguration.swift:199-203`).

## What never leaves the Mac

<!-- openwiki: broken internal link [/openwiki/concepts/chat-history.md] link "/openwiki/concepts/chat-history.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- **Chats, saved screenshots and the notepad** are stored only on disk ([Chat history](/openwiki/concepts/chat-history.md)).
- **Windows elfhub never captures:**
  - elfhub's own windows (overlay, panels, notepad);
  - windows of apps on the privacy blocklist.
<!-- openwiki: broken internal link [/openwiki/workflows/screen-targeting-and-actions.md] link "/openwiki/workflows/screen-targeting-and-actions.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
  These are left out of the ScreenCaptureKit filter, so their pixels are never captured at all ([Screen targeting](/openwiki/workflows/screen-targeting-and-actions.md)).
- **There is no telemetry.**

## Related pages

<!-- openwiki: broken internal link [/openwiki/concepts/providers-configuration-and-persistence.md] link "/openwiki/concepts/providers-configuration-and-persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Model layers and secrets](/openwiki/concepts/providers-configuration-and-persistence.md)
<!-- openwiki: broken internal link [/openwiki/architecture/system-overview.md] link "/openwiki/architecture/system-overview.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [System overview](/openwiki/architecture/system-overview.md)
