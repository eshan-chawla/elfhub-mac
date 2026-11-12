---
type: persistence-concept
title: Chat History and On-Device Storage
description: How elfhub records typed and spoken turns as local JSON conversations. Covers optional screenshots with vector marks and user ink, saved notepads, the quiet-period split for voice turns, reopening a chat into the model's history, and the privacy switches.
tags: [chat-history, persistence, json, privacy, screenshots, notepad, conversation]
verified:
  - by: openwiki/0.6.1
    at: 2026-11-04T04:23:07.759Z
sources:
  - id: openwiki-source-21b32db599c2be50e82016f5
    resource: repo://elfhub/ChatConversationStore.swift
  - id: openwiki-source-bd209bdd215e9ea8ba01a3c7
    resource: repo://elfhub/TextChatView.swift
  - id: openwiki-source-48041cf7cdf2b03e8f86ce8c
    resource: repo://elfhubTests/ChatHistoryTests.swift
generated: { by: "claude-code", at: "2026-11-04T04:23:07.759Z" }
---

# Chat History and On-Device Storage

All chats stay on the Mac. `ChatConversationStore` writes one JSON file per conversation to `~/Library/Application Support/elfhub/Conversations/<conversation id>.json`. A file is written only while "Save chats on this Mac" is on (`elfhub/ChatConversationStore.swift:5-10`, `:247-253`, `:398-410`).

## Data model

- **`ChatConversation`** holds an id, a title (taken from the first user message, at most 48 characters), created and updated dates, and an ordered list of `StoredChatMessage`s (`elfhub/ChatConversationStore.swift:93-125`, `:216-228`).
- **`StoredChatMessage`** has a role (user or assistant), text, a date, `isError`, and `inputSource` (typed or spoken). It also has these optional attachments (`elfhub/ChatConversationStore.swift:17-91`):

| Field | Lives on | What it is |
|---|---|---|
| `screenshotFileName` | question | The JPEG the turn sent to the model, before the user's ink. |
| `userInk` (`SavedUserInk`) | question | What the user drew while holding push-to-talk, as display-local vector data. |
| `screenGuidance` (`SavedScreenGuidance`) | reply | The pointer and marks elfhub drew, as display-local AppKit points. Never a second image. |
| `notepad` (`SavedNotepad`) | reply | The whole notepad the reply wrote: title plus markdown lines. |

Decoding uses `decodeIfPresent` for every field added after the first release, so chats saved by earlier builds still load (`elfhub/ChatConversationStore.swift:77-90`).

## One exchange API for typed and spoken turns

`TextChatViewModel` (one instance, owned by `CompanionManager`) records both kinds of turn the same way (`elfhub/TextChatView.swift:106-211`):

1. **`beginExchange(userText:inputSource:)`** appends the question and an empty reply bubble, saves, and returns a `RecordedExchange` (conversation, question and reply ids). A spoken question that arrives more than 30 minutes after the last message starts a new conversation first (`elfhub/ChatConversationStore.swift:184-192`).
2. **`showStreamingReply(rawReplyText:for:)`** fills the reply bubble with the speakable text while the reply streams. Guidance and notepad tags are hidden, including half-written ones. It is not written to disk.
3. The turn then ends in one of three ways:
   - **`completeExchange(_:with:)`** replaces the text with the decoder's clean `spokenText`. It saves the screenshot when allowed, records the ink and marks with that screenshot, and records the notepad.
   - **`saveInterruptedExchange(_:rawReplyTextSoFar:)`** keeps what streamed so far, including a notepad parsed from the partial text.
   - **`failExchange(_:with:)`** turns the reply into an error bubble. Error bubbles are never sent back to the model.

Because each update is addressed by conversation id, a reply that finishes after the user has switched chats still lands in the right conversation (`elfhub/TextChatView.swift:192-210`).

## Screenshots and marks (optional)

"Save screenshots with chats" is off by default. Screenshots are kept only while it and chat saving are both on (`elfhub/ChatConversationStore.swift:236-239`, `:321-331`).

- **Storage.** A saved screenshot goes to `Conversations/Screenshots/<conversation id>/<message id>.jpg`.
- **Only one image per question.** The reply's marks and the user's ink are stored as vector data and redrawn over that one image by the overlay's own views, in static mode.
- **No marks without an image.** `recordScreenshot` writes nothing when there is no saved file (`elfhub/ChatConversationStore.swift:132-149`, `:333-352`).
- **`screenshotExchange(containingMessageWithIdentifier:)`** finds the question and reply pair from either bubble, for the Before / After viewer (`elfhub/ChatConversationStore.swift:158-182`).

Deleting a chat also deletes its screenshot folder. "Delete saved screenshots" removes every image and keeps the chats (`elfhub/ChatConversationStore.swift:288-305`, `:363-367`).

## Back into the model's memory

- **Opening a saved chat** replaces the pipeline's history with `historyTurns(maximumTurnCount: 10)`. That is the completed question and reply pairs, oldest first, with error bubbles and unanswered questions skipped. A reply's notepad is appended to its text, exactly as in a live turn (`elfhub/ChatConversationStore.swift:194-214`, `elfhub/TextChatView.swift:60-68`).
- **Starting a new chat** clears the pipeline history.

## Privacy switches

The switches live in Settings › Privacy:

- **Saving chats** (on by default). Turning it on writes this session's chats to disk. Turning it off stops writing but keeps existing files.
- **Saving screenshots** (off by default).
- **Delete all chats.**
- **Delete saved screenshots.**
- **Reveal the folder in Finder.**

(`elfhub/ChatConversationStore.swift:307-317`, `:391-394`)

## Tests

`ChatHistoryTests` covers, among other things:

- legacy JSON loading;
- the quiet-period split;
- screenshots being off by default;
- deleting a chat together with its screenshots;
- guidance and ink stored relative to the captured display;
- "marks only with a saved screenshot";
- finding an exchange from either bubble.

Notepad persistence is covered in `NotepadTests`.

## Related pages

<!-- openwiki: broken internal link [/openwiki/workflows/conversation-turn.md] link "/openwiki/workflows/conversation-turn.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [A conversation turn](/openwiki/workflows/conversation-turn.md)
<!-- openwiki: broken internal link [/openwiki/workflows/notepad.md] link "/openwiki/workflows/notepad.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Notepad](/openwiki/workflows/notepad.md)
<!-- openwiki: broken internal link [/openwiki/concepts/providers-configuration-and-persistence.md] link "/openwiki/concepts/providers-configuration-and-persistence.md" is root-absolute, which no real consumer resolves against the repository root (not a coding agent reading the page, not GitHub's Markdown renderer, not a local viewer); use a path relative to this file instead. Fix the href or restore the target, then delete this comment. -->
- [Model layers and secrets](/openwiki/concepts/providers-configuration-and-persistence.md)
