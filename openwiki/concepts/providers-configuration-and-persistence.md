---
type: configuration-concept
title: Model Layers, Provider Configuration, and Secrets
description: How each of the three model layers (speech-to-text, language model, text-to-speech) is chosen, configured and persisted. Covers the provider catalog, model capabilities, keys in the Keychain, preferences in UserDefaults, and on-device models through Ollama and Apple speech.
tags: [providers, configuration, keychain, userdefaults, ollama, speech-to-text, text-to-speech, capabilities]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-803ef223e84bdb73e11a5779
    resource: repo://elfhub/BuddyTranscriptionProvider.swift
  - id: openwiki-source-e2c892c223ac06c0fa85911d
    resource: repo://elfhub/CompanionManager.swift
  - id: openwiki-source-be20e05db90b17df4a71ae3d
    resource: repo://elfhub/CompanionTurnPipeline.swift
  - id: openwiki-source-0d9ca73f676a663d6252ea50
    resource: repo://elfhub/KeychainSecretStore.swift
  - id: openwiki-source-e965c20fb4b80c1511c0fb20
    resource: repo://elfhub/LanguageModelProvider.swift
  - id: openwiki-source-b0b80820cc673c5643b55264
    resource: repo://elfhub/OnDeviceModelAssistant.swift
  - id: openwiki-source-a029dd64bff6ed4aa5751b24
    resource: repo://elfhub/ProviderConfiguration.swift
  - id: openwiki-source-1e1b65e9ef37c7a4176fa557
    resource: repo://elfhub/ProviderConfigurationStore.swift
  - id: openwiki-source-8969b4bc944ef3945041dbd0
    resource: repo://elfhub/SpeechSynthesisProvider.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Model Layers, Provider Configuration, and Secrets

elfhub has three model layers, configured independently in Settings › Models and in onboarding step 1. Nothing is hosted by elfhub: every layer is either on-device or a service the user has a key for.

## Language model

### `ProviderConfiguration`

A configuration describes one endpoint and stores everything except the key (`elfhub/ProviderConfiguration.swift:59-118`):

- `kind`: `anthropic`, `openAICompatible` or `gemini`;
- display name, base URL and model id;
- `supportsVision`;
- `coordinateConvention`: image pixels, 0–999 or 0–1000;
- `supportsToolCalling`;
- `presetIdentifier`.

Kind defaults:

- **Tool calling** is on for Anthropic and Gemini. It is off for OpenAI-compatible endpoints, because local servers vary.
- **Coordinates** are image pixels for Anthropic and OpenAI-compatible endpoints, and 0–999 for Gemini (`elfhub/ProviderConfiguration.swift:38-56`).

Custom decoding fills fields that were added later with the kind's defaults and ignores the old hosted-proxy flag, so configurations from earlier builds still load.

Derived values:

- `visionProfile` sets the screenshot size limits: Anthropic models use their known limits, everything else a conservative generic size.
- `languageModelCapabilities` bundles vision, tool calling and that profile.
- `requiresAPIKey` is false only for an OpenAI-compatible endpoint on a local host.

(`elfhub/ProviderConfiguration.swift:120-153`)

### Catalog and store

`LanguageModelProviderCatalog` presets fill in the base URL, kind, suggested model, key page and defaults for two groups (`elfhub/LanguageModelProviderCatalog.swift:16-62`):

- **cloud APIs:** Anthropic, OpenAI, Gemini, OpenRouter, Mistral, xAI, Groq, DeepSeek, Together;
- **on this Mac:** Ollama, LM Studio, llama.cpp, custom.

Most presets leave the model empty, and "Detect models" lists what the account offers: `/models` for OpenAI-compatible endpoints, `/v1/models` for Anthropic, Gemini's `models` list (`elfhub/ProviderConfigurationStore.swift:177-260`). "Test connection" sends a tiny real request through the provider.

`ProviderConfigurationStore` persists the list as JSON under the UserDefaults key `llmProviderConfigurations`, and the active id under `activeLLMProviderID`. A stored active id that no longer exists falls back to the first configuration. With no configurations at all, nothing is active and turns fail with "add a model in Settings, under Models". No default model is created (`elfhub/ProviderConfigurationStore.swift:14-60`, `:104-110`).

A configuration is ready when it has a model and, if it needs one, a key (`elfhub/ProviderConfigurationStore.swift:42-54`).

`makeActiveProvider()` builds a fresh provider for every turn, so edits apply on the next turn:

| Kind | Provider |
|---|---|
| Anthropic | `AnthropicLanguageModelProvider` over `ClaudeAPI` |
| OpenAI-compatible | `OpenAICompatibleLanguageModelProvider` |
| Gemini | `GeminiLanguageModelProvider` |

A missing Anthropic or Gemini key is a `missingConfiguration` error that names the fix (`elfhub/ProviderConfigurationStore.swift:104-151`).

### The provider protocol

`LanguageModelProvider` exposes `displayName`, `capabilities` and one `streamResponse(_:onStreamEvent:)`. The request carries a system prompt, content-block messages and tool definitions, with `maxOutputTokens` defaulting to 2048. Content blocks are:

- text;
- image;
- tool call;
- tool result;
- `anthropicRawBlock`, which preserves Claude thinking blocks verbatim.

Streaming is delta-only (`textDelta`), and the final response carries the full text, the tool calls and the assistant content to replay (`elfhub/LanguageModelProvider.swift:23-172`). Errors are normalized into `LanguageModelProviderError`: `invalidResponse`, `httpError`, `missingConfiguration`.

## Speech-to-text

`TranscriptionProviderChoice` is persisted under `transcriptionProviderChoice`:

- `appleOnDevice` (the default): SpeechAnalyzer on macOS 26+, otherwise SFSpeechRecognizer;
- `assemblyAI` (raw value `assemblyAIOwnKey`, kept from earlier builds);
- `openAICompatibleWhisper`, with `WhisperTranscriptionEndpointPreset`s for OpenAI, Groq and a local faster-whisper server.

(`elfhub/BuddyTranscriptionProvider.swift:40-130`)

`CompanionManager.applyTranscriptionProviderChoice()` rebuilds the provider through `BuddyTranscriptionProviderFactory` whenever the choice, a key or the Whisper settings change. The swap waits if a dictation is in progress (`elfhub/CompanionManager.swift:346-370`).

## Text-to-speech

`SpeechOutputMode` is persisted under `speechOutputMode`:

- `system` (Apple on-device; the default);
- `elevenLabs` (raw value `elevenLabsOwnKey`);
- `openAICompatibleSpeech`, with presets for OpenAI and local Kokoro;
- `off`, for captions only.

(`elfhub/SpeechSynthesisProvider.swift:22-118`)

A voice that isn't set up yet, such as one with a missing key, quietly uses the on-device voice. A voice that fails mid-reply also continues on-device (`elfhub/CompanionManager.swift:224-293`).

## Secrets and preferences

`KeychainSecretStore` stores every key as a generic password under the service `so.elfhub.secrets`, accessible after first unlock (`elfhub/KeychainSecretStore.swift:13-79`):

- **Model provider keys** use the account `provider-key-<configuration id>`.
- **Speech-service keys** use `ServiceSecretAccount`: AssemblyAI, ElevenLabs, OpenAI-compatible transcription, OpenAI-compatible speech.

Writes delete the old item first, so there are never duplicates. An empty or nil secret clears it. `upsert(_:apiKey:)` leaves the key alone for `nil` and clears it for `""`. Deleting a configuration deletes its key (`elfhub/ProviderConfigurationStore.swift:64-96`).

Non-secret preferences live in UserDefaults:

- input mode;
- voice and ElevenLabs voice id;
- transcription choice and Whisper URL/model;
- OpenAI-compatible speech URL, model and voice;
- push-to-talk shortcut;
- action mode and execution mode;
- onboarding and screen-content flags;
- chat-saving switches;
- the privacy blocklist.

Keys never go into UserDefaults or the bundle.

## On-device models

`OnDeviceModelAssistant` only talks to Ollama on `http://localhost:11434` (`elfhub/OnDeviceModelAssistant.swift:5-12`, `:235-237`):

- **Status:** `/api/version`.
- **Installed models:** `/api/tags`.
- **Downloads:** `/api/pull`, with NDJSON progress accumulated by `OllamaPullProgressAccumulator`.
- **Deletes:** `/api/delete`.
- **Capabilities:** `/api/show`.

"Use" either activates an existing Ollama configuration for that model or creates one. The new configuration takes its vision and tool-calling settings from the model's reported capabilities, and its coordinate convention from `OnDeviceModelCatalog` (`elfhub/OnDeviceModelAssistant.swift:384-407`). The assistant can also pre-download Apple's SpeechTranscriber model on macOS 26+.

## Related pages

<!-- openwiki: broken internal link [/openwiki/integrations/external-services.md] link "/openwiki/integrations/external-services.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [External services](/openwiki/integrations/external-services.md)
<!-- openwiki: broken internal link [/openwiki/workflows/conversation-turn.md] link "/openwiki/workflows/conversation-turn.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [A conversation turn](/openwiki/workflows/conversation-turn.md)
<!-- openwiki: broken internal link [/openwiki/concepts/chat-history.md] link "/openwiki/concepts/chat-history.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Chat history](/openwiki/concepts/chat-history.md)
