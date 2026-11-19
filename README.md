# elfhub

<p>
  <a href="https://github.com/eshan-chawla/elfhub-mac/releases/latest/download/elfhub.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download elfhub for macOS" height="36"></a>
</p>

<sub>Public beta · macOS 14.2 or later on Apple silicon (M1 or newer) · free and open source (AGPL-3.0) · signed and notarized by Apple · <a href="https://github.com/eshan-chawla/elfhub-mac/releases">all releases</a></sub>

An AI desktop companion for macOS. elfhub lives in your menu bar — it can see your screen, talk to you, point at and annotate what matters, and take actions on your computer on request. It works alongside the agent you're hacking with: performing real computer use in front of the agent to move your task along, and helping you learn new things as you work.

elfhub is **desktop-first and bring-your-own-key**: there is no elfhub server, account or analytics. You choose each model layer yourself — a cloud API with your own key, or a model running on your Mac — and the only requests that leave the app are the API calls to the services you picked, plus a once-a-day check on GitHub for a newer version of elfhub (it sends only the app's version; turn it off in Settings › General), and on-device speech and voice models downloaded from Hugging Face when you press Download (anonymously). Already pay for ChatGPT? **Continue with ChatGPT** lets elfhub answer with OpenAI models included in your plan, no API key needed. Keys and sign-ins live in your Keychain; chats are saved only on your Mac. Elfs you let use the web (your other Elfs by default) also send their search words to the search service you pick and open the pages they're led to — straight from this app, never through an elfhub server. Two things are sent to your chosen language model in the background, and both can be switched off in Settings › Privacy & permissions: a quiet chat's text, to build your main Elf's memory, and a chat's first question and answer, to give it a short title.

## What it does

- **Sees your screen** — takes a screenshot of the display your mouse is on, only when you press the hotkey or send a chat message — or, for a background task, after you say yes to letting it use the screen.
- **Hears you** — hold the push-to-talk shortcut (`Control + Option` by default) anywhere to speak. While holding it, press and drag the mouse to circle or underline what you mean — a blue line follows your cursor (your Elf draws in orange, so the two never mix), and the model sees your marks on the screenshot. Press **Esc** anytime to stop elfhub — while it listens, thinks, talks or acts.
- **Thinks and answers** — your transcript (+ a screenshot, if your model can see images) goes to the language model you configure. Replies stream as text, and optionally as voice.
- **Points and annotates** — a pointer appears right at the UI element the model refers to, and marks (highlights, circles, arrows, notes) are drawn on screen, on any monitor.
- **Writes it down** — when an explanation is easier to follow written (steps, a command, some code), elfhub opens a notepad window at the top right of your screen and writes it line by line as it talks. It stays until you close it, the text is selectable, and its copy button gives plain text (or Markdown from its menu). Every notepad is saved with the reply in Chat.
- **Acts on your machine (with consent)** — click, type, scroll, or press shortcuts. Every action goes through a per-turn consent gate: only your own words asking elfhub to *do* something count as consent, and Esc stops it instantly.
- **Text chat too** — type instead of talking whenever you want. Everything you ask, typed or spoken, is saved on your Mac and shows up in Chat (turn it off or delete it in Settings). Optionally, the screenshot each question sent can be kept too (off by default): it sits in a collapsible row under the message, opens in an in-app viewer, and when you or elfhub drew on it you can switch Before / After between the original and the marked-up version — the drawing and marks are redrawn from saved data, so only one image is stored.

## Your Elf

The assistant is your **Elf**. You name it when you set elfhub up, and it lives in a folder on your Mac (its page at the top of the sidebar, or `~/Library/Application Support/elfhub/Elfs/main`):

- **`soul.md`** — instructions it follows in every reply. You write it; the Elf can only suggest changes.
- **`user.md`** — what it knows about you and what you've talked about, as the Elf noted it (your main Elf also folds quiet chats into it — its memory). Edit or clear it anytime.
- **`skills/`** — working knowledge, one folder per skill with a `SKILL.md` (the same layout Hermes and other agentskills.io agents use, so their skills can be dropped in).
- **`elf.json`** — its name, how it answers (reply length, tone, language) and the setup it was used with (never your keys).
- **`files/`** — its own working files.

The soul, notes and skills go to your language model with each question, like the rest of the conversation. You can add more Elfs from the **+** next to Elfs in the sidebar (or the Researcher and Writer starters); each has its own page, folder, soul and skills, and can take on longer work as a background task. **Export Elf…** on an Elf's page saves a `.elf` file with its config, soul, skills and `files/`; `user.md` is included unless you switch it off, and its chats only if you switch them on. Keys and folder access are never included.

## The three model layers

| Layer | Options |
|-------|---------|
| **Speech-to-text** | On-device Apple recognition (default, private), AssemblyAI (your key), or any Whisper / OpenAI-compatible endpoint — OpenAI, Groq, or a local faster-whisper server |
| **Language model** | Your ChatGPT plan (Continue with ChatGPT — no key; pick a fallback model for when the plan's usage limit is reached), or Anthropic, OpenAI, Google Gemini, OpenRouter, Mistral, xAI, Groq, DeepSeek, Together AI (your key) — or Ollama, LM Studio, llama.cpp on your Mac, or any other OpenAI-compatible endpoint. **Multimodal is optional:** a model that sees images can look at your screen and point; a text-only model still talks and chats |
| **Text-to-speech** | On-device Apple voices (default), ElevenLabs (your key), any OpenAI-compatible speech endpoint — OpenAI, or a local Kokoro server — or off |

The **on-device model assistant** (Models → On-device models) finds Ollama, downloads recommended vision models with live progress, and switches elfhub to them in a click. It can also pre-download Apple's on-device speech model (macOS 26+).

## Install

1. [Download `elfhub.dmg`](https://github.com/eshan-chawla/elfhub-mac/releases/latest/download/elfhub.dmg) (always the latest version).
2. Open it and drag **elfhub** into **Applications**.
3. Open elfhub from Applications. It's signed and notarized, so macOS only asks you to confirm opening an app downloaded from the internet.

elfhub keeps itself up to date: once a day it checks GitHub Releases, and when a new version is out it shows what's new with **Install**, **Remind me later** and **Skip**. Nothing is installed until you click Install (or switch on automatic installs). Every update is signed, so only real elfhub releases can install. Change this in Settings › General, or use **elfhub › Check for Updates…**. Your settings, keys and chats stay where they are.

## First launch

Setup is six short steps, one decision each:

1. **Welcome.**
2. **Your Elf** — keep the suggested name or pick your own; optionally add the Researcher and Writer starter Elfs.
3. **Model** — Continue with ChatGPT, use an API key, or run a model on your Mac.
4. **Voice** — how your Elf hears you, and an optional natural voice that runs on your Mac.
5. **Shortcut and permissions** — keep or change the push-to-talk shortcut and grant permissions. Screen Recording takes effect after elfhub restarts; setup picks up where you left it.
6. **Your data** — what stays on your Mac (saving chats is on, screenshots off, the action log on — change them later in Settings › Privacy & permissions), and whether to start the tutorial: a short hands-on walkthrough you can skip or replay from Settings › General.

## Build and run

Prerequisites: an Apple silicon Mac with macOS 14.2+, and Xcode 26+ with its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), which the on-device speech engine (MLX) needs.

```bash
open elfhub.xcodeproj
```

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` and `ELFHUB_BUNDLE_IDENTIFIER` (a free Personal Team works).
2. Select the `elfhub` scheme.
3. Hit **Cmd + R** to build and run.

Build from Xcode rather than `xcodebuild` in a terminal — terminal builds reset macOS privacy permissions (Screen Recording, Accessibility, …).

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture (not needed in text-only mode)
- **Speech Recognition** — for Apple's on-device speech-to-text and saying "stop" during screen actions
- **Accessibility** — for the global keyboard shortcut and screen actions
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture (short version)

A macOS app with three main pieces: a chat-first main window (your Elfs and chats in the sidebar; Settings — General, Models, Tools & capabilities, Controls, Privacy & permissions — at the bottom of it), a floating menu-bar control panel, and a full-screen click-through guidance overlay. Push-to-talk captures audio and transcribes it with the chosen speech-to-text layer, sends the transcript + screenshot to the active language model via streaming, and speaks the reply sentence by sentence with the chosen voice. On multiple monitors only the screen under your mouse is captured, and pointing lands on that screen.

Full technical breakdown: `CLAUDE.md` / `AGENTS.md` (agents read this).

## Project structure

```
elfhub/          # Swift source
  elfhubApp.swift                    App entry
  MainAppView.swift                  Main window, onboarding, tutorial
  CompanionManager.swift             Central state machine
  ModelLayerComponents.swift         Speech-to-text / language model / voice setup UI
  LanguageModelProviderCatalog.swift Provider presets
  OnDeviceModelAssistant.swift       Ollama + Apple speech model downloads
  ChatConversationStore.swift        Chats saved on this Mac
  GuidedTutorialController.swift     The optional walkthrough
  CompanionPanelView.swift           Menu bar panel UI
  OverlayWindow.swift                Guidance overlay (pointer, annotations, status pill)
  BuddyDictation*.swift              Push-to-talk pipeline
  AppUpdateController.swift          Sparkle updates (published app only)
elfhubTests/     # Unit tests
elfhubUITests/   # UI tests
brand/           # App icon artwork (all rights reserved, not AGPL — see brand/LICENSE.md)
scripts/         # Release, DMG and icon scripts
```

## Contributing

elfhub is licensed under the [GNU AGPL v3.0](LICENSE) — fork it, hack on it, build your own version. PRs welcome.

The app icon is the exception: the igloo icon, menu bar icon and artwork (`brand/` and the app's icon images) are all rights reserved and not part of the open-source licence. If you ship your own build, give it your own icon — see [brand/LICENSE.md](brand/LICENSE.md).

If you're using Claude Code (or another agent), point it at `CLAUDE.md` — it already knows the codebase.
