# Security policy

elfhub can see your screen, hear you, and click and type on your Mac, so security reports matter a lot. Thank you for taking the time to send one.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Instead, email **eshan.chawla.off@gmail.com** with:

- what the problem is and what an attacker could do with it
- steps to reproduce (a screen recording helps)
- the elfhub version (Settings › General, or the release you downloaded) and your macOS version

You can also use GitHub's private reporting: the **Security** tab → **Report a vulnerability**.

I'll reply as soon as I can, keep you posted while it's fixed, and credit you in the release notes if you'd like.

## What counts

Especially welcome:

- screen actions (click, type, keys) that run without the user's consent, or get around the consent card or Esc
- API keys or ChatGPT sign-in tokens leaving the Keychain, or being sent anywhere other than the service they belong to
- screenshots, audio, chats or the action log leaving the Mac other than to the model services the user chose
- windows of privacy-blocklisted apps (password managers and similar) appearing in screenshots
- problems with the signed and notarized release builds

Out of scope: issues in the third-party model services themselves, and what a model chooses to say.

## Supported versions

Only the [latest release](https://github.com/eshan-chawla/elfhub/releases/latest) gets security fixes.
