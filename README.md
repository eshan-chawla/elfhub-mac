# elfhub

<p>
  <a href="https://github.com/eshan-chawla/elfhub/releases/latest/download/elfhub.dmg"><img src="https://img.shields.io/badge/Download_for_macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download elfhub for macOS" height="36"></a>
</p>

<sub>macOS 14.2 or later · free and open source (AGPL-3.0) · signed and notarized by Apple · <a href="https://github.com/eshan-chawla/elfhub/releases">all releases</a></sub>

An AI desktop companion for macOS. elfhub lives in your menu bar — it can see your screen, talk to you, point at and annotate what matters, and take actions on your computer on request. It works alongside the agent you're hacking with: performing real computer use in front of the agent to move your task along, and helping you learn new things as you work.

elfhub is **desktop-first and bring-your-own-key**: there is no elfhub server, account, analytics or update feed. You choose each model layer yourself — a cloud API with your own key, or a model running on your Mac — and the only requests that leave the app are the API calls to the services you picked. Already pay for ChatGPT? **Continue with ChatGPT** lets elfhub answer with OpenAI models included in your plan, no API key needed. Keys and sign-ins live in your Keychain; chats are saved only on your Mac.

## What it does

- **Sees your screen** — takes a screenshot of the display your mouse is on, only when you press the hotkey or send a chat message (nothing runs in the background).
- **Hears you** — hold the push-to-talk shortcut (`Control + Option` by default) anywhere to speak. While holding it, press and drag the mouse to circle or underline what you mean — an orange line follows your cursor, and the model sees your marks on the screenshot. Press **Esc** anytime to stop elfhub — while it listens, thinks, talks or acts.
- **Thinks and answers** — your transcript (+ a screenshot, if your model can see images) goes to the language model you configure. Replies stream as text, and optionally as voice.
- **Points and annotates** — a pointer appears right at the UI element the model refers to, and marks (highlights, circles, arrows, notes) are drawn on screen, on any monitor.
- **Writes it down** — when an explanation is easier to follow written (steps, a command, some code), elfhub opens a notepad window at the top right of your screen and writes it line by line as it talks. It stays until you close it, the text is selectable, and its copy button gives plain text (or Markdown from its menu). Every notepad is saved with the reply in Chat.
- **Acts on your machine (with consent)** — click, type, scroll, or press shortcuts. Every action goes through a per-turn consent gate: only your own words asking elfhub to *do* something count as consent, and Esc stops it instantly.
- **Text chat too** — type instead of talking whenever you want. Everything you ask, typed or spoken, is saved on your Mac and shows up in Chat (turn it off or delete it in Settings). Optionally, the screenshot each question sent can be kept too (off by default): it sits in a collapsible row under the message, opens in an in-app viewer, and when you or elfhub drew on it you can switch Before / After between the original and the marked-up version — the drawing and marks are redrawn from saved data, so only one image is stored.

## Your elf

The assistant is your **elf**. You name it when you set elfhub up, and it lives in a folder on your Mac (its page under Elves in the sidebar, or `~/Library/Application Support/elfhub/Elves/main`):

- **`soul.md`** — instructions it follows in every reply. You write it; the elf can only suggest changes.
- **`profile.md`** — your personal preferences, as the elf noted them. Edit or clear it anytime.
- **`skills/`** — working knowledge, one folder per skill with a `SKILL.md` (the same layout Hermes and other agentskills.io agents use, so their skills can be dropped in).
- **`elf.json`** — its name, how it answers (reply length, tone, language) and the setup it was used with (never your keys).
- **`files/`** — its own working files.

The soul, profile and skills go to your language model with each question, like the rest of the conversation. You can add more elves from the **+** next to Elves in the sidebar (or the Researcher and Writer starters); each has its own page, folder, soul and skills. **Export elf…** saves a `.elf` file with its config, soul and skills; your profile and its files are only included if you switch them on.

## The three model layers

| Layer | Options |
|-------|---------|
| **Speech-to-text** | On-device Apple recognition (default, private), AssemblyAI (your key), or any Whisper / OpenAI-compatible endpoint — OpenAI, Groq, or a local faster-whisper server |
| **Language model** | Your ChatGPT plan (Continue with ChatGPT — no key; pick a fallback model for when the plan's usage limit is reached), or Anthropic, OpenAI, Google Gemini, OpenRouter, Mistral, xAI, Groq, DeepSeek, Together AI (your key) — or Ollama, LM Studio, llama.cpp on your Mac, or any other OpenAI-compatible endpoint. **Multimodal is optional:** a model that sees images can look at your screen and point; a text-only model still talks and chats |
| **Text-to-speech** | On-device Apple voices (default), ElevenLabs (your key), any OpenAI-compatible speech endpoint — OpenAI, or a local Kokoro server — or off |

The **on-device model assistant** (Models → On-device models) finds Ollama, downloads recommended vision models with live progress, and switches elfhub to them in a click. It can also pre-download Apple's on-device speech model (macOS 26+).

## Install

1. [Download `elfhub.dmg`](https://github.com/eshan-chawla/elfhub/releases/latest/download/elfhub.dmg) (always the latest version).
2. Open it and drag **elfhub** into **Applications**.
3. Open elfhub from Applications. It's signed and notarized, so macOS only asks you to confirm opening an app downloaded from the internet.

elfhub doesn't update itself. To update, download the latest DMG and replace the app in Applications. Your settings, keys and chats stay where they are.

## First launch

1. **Models** — pick speech-to-text, a language model, and a voice.
2. **Shortcuts & permissions** — keep or change the push-to-talk shortcut, grant permissions, choose what stays on your Mac (saving chats is on, screenshots off, the action log on — change them here or later in Settings › Privacy), and leave **Start tutorial** checked (or uncheck it) before finishing.
3. **Tutorial (optional)** — a short hands-on walkthrough: talk, get pointed at something, clear it with Esc, and chat. Skip any step or end it anytime; replay it from Settings.

## Build and run

Prerequisites: macOS 14.2+ and Xcode 16+.

```bash
open elfhub.xcodeproj
```

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` and `ELFHUB_BUNDLE_IDENTIFIER` (a free Personal Team works).
2. Select the `elfhub` scheme.
3. Hit **Cmd + R** to build and run.

Build from Xcode rather than `xcodebuild` in a terminal — terminal builds reset macOS privacy permissions (Screen Recording, Accessibility, …).

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture (not needed in text-only mode)
- **Accessibility** — for the global keyboard shortcut and screen actions
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture (short version)

A macOS app with three main pieces: a chat-first main window (every chat in the sidebar; Settings — models, modes, shortcuts, permissions, privacy, general — behind the sidebar's bottom menu), a floating menu-bar control panel, and a full-screen click-through guidance overlay. Push-to-talk captures audio and transcribes it with the chosen speech-to-text layer, sends the transcript + screenshot to the active language model via streaming, and speaks the reply sentence by sentence with the chosen voice. On multiple monitors only the screen under your mouse is captured, and pointing lands on that screen.

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
elfhubTests/     # Unit tests
elfhubUITests/   # UI tests
brand/           # App icon artwork (all rights reserved, not AGPL — see brand/LICENSE.md)
scripts/         # Release, DMG and icon scripts
```

## Contributing

elfhub is licensed under the [GNU AGPL v3.0](LICENSE) — fork it, hack on it, build your own version. PRs welcome.

The app icon is the exception: the igloo icon, menu bar icon and artwork (`brand/` and the app's icon images) are all rights reserved and not part of the open-source licence. If you ship your own build, give it your own icon — see [brand/LICENSE.md](brand/LICENSE.md).

If you're using Claude Code (or another agent), point it at `CLAUDE.md` — it already knows the codebase.
