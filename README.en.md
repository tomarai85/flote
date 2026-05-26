# Flote

[![License: FSL-1.1-ALv2](https://img.shields.io/badge/license-FSL--1.1--ALv2-blue.svg)](./LICENSE.md)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](https://flote-app.vercel.app)
[![Status: beta](https://img.shields.io/badge/status-free%20beta-2dd4bf.svg)](https://flote-app.vercel.app)
[![A Direct product](https://img.shields.io/badge/-a%20Direct%20product-0a0a0f.svg)](https://direct-homepage.vercel.app)

> **Scribbles, auto-organized.**
>
> Hit Option+Space. A 160px sticky note floats over whatever you were doing. Type whatever you were thinking. Press Organize. AI turns it into a title, a one-liner, and a checkbox action list. That's the whole product.

- Repository: https://github.com/tomarai85/flote
- Website: https://flote-app.vercel.app (= screenshots, full install guide, roadmap)
- Parent brand: [a Direct product](https://direct-homepage.vercel.app)
- License: [FSL-1.1-ALv2](./LICENSE.md) (= auto-converts to Apache 2.0 after 2 years)
- Security: [report vulnerabilities via SECURITY.md](./SECURITY.md)
- Status: **free beta** / macOS 14 (Sonoma)+ / Apple Silicon

[日本語 README](./README.md)

---

## Why Flote

Most note apps are designed for people who are good at organizing.
Notion, Obsidian, Apple Notes — they all assume you can design tags, build hierarchies, and link things together on your own.

Some of us can't. Some of us don't want to.
**We just want to dump a fleeting thought somewhere before it evaporates from our head. We'll organize it later. (Spoiler: we won't.)**
There hasn't really been a note app built around that.

Flote tries to fill that gap.

- Resident in the menu bar; Option+Space drops a 160px sticky onto your desktop in about two seconds.
- The Organize button structures the scribble into a title, a summary, and an action checklist.
- Notes live on your Mac. Nothing is uploaded to a cloud (= only the Organize call hits an API; using local Ollama keeps it fully offline).
- Native SwiftUI + AppKit. Not an Electron wrapper.

A note app for people who can't organize, that hands back something organized.

---

## Install / Quick Start

### macOS

Easiest path is the official website:

→ https://flote-website.vercel.app

Or paste this one-liner into Terminal (= same install hero as the LP):

```
curl -fsSL -o /tmp/Flote.zip https://flote-app.vercel.app/Flote.zip && \
  unzip -oq /tmp/Flote.zip -d /Applications/ && \
  open /Applications/Flote.app
```

After first launch:

1. A **Flote** icon appears in the menu bar.
2. Press `Option + Space` to float a sticky.
3. Write something, then hit Organize for AI structuring.

AI Organize (optional, ~5 min setup): install [Ollama](https://ollama.com/download/mac) and run `ollama pull gemma3` to use local AI. For longer or messier notes, paste a Claude API key into Settings to route through Claude.

> ⚠️ The Mac app is not currently part of the Apple Developer Program, so first launch will trip Gatekeeper ("cannot verify the developer"). Right-click the app → Open → Open. Properly signed + notarized builds are planned for Phase 2.

### Build from source

```
cd apps/macos
open Flote.xcodeproj   # Xcode 16+ / Swift 5.10+
```

Press `Cmd + R` to run. The dev API-key fallback file (`DevSecrets.swift`) is gitignored and is not part of the published repo; runtime keys go through the Settings UI into the Keychain.

---

## Features

| Feature | What it does |
|---|---|
| **Resident floating sticky** | Menu-bar resident; `Option+Space` floats a 160px sticky over any app. |
| **AI Organize** | One button turns a scribble into title / summary / checkbox actions. Short notes use local Ollama; long notes route through Claude. |
| **Learning classifier** | The more you use it, the better Flote routes new notes into the right Group. |
| **Inbox batch organize** | Empty an entire Inbox of unclassified notes in one click. |
| **Undo** | Don't like the Organize output? `Cmd+Z` puts the scribble back. |
| **Custom shortcuts** | Rebind New Note / Show Groups / Archive to whatever keys you like. |
| **Local-first data** | Notes stay on your Mac. The only network traffic is the AI Organize call (= zero traffic when using Ollama). |

See the Before/After section on the LP for worked examples: https://flote-website.vercel.app

---

## License -- FSL-1.1-ALv2

Flote ships as **source-available** software:

- **Allowed today** (= Permitted Purpose):
  - Personal use (= running Flote on your own Mac as an end user).
  - Internal use (= deploying it inside your company / lab to your own employees, contractors, or researchers).
  - Non-commercial education and research.
  - Reading the source, modifying it, maintaining a private fork.
- **Not allowed** (= Competing Use):
  - Hosting Flote as a paid SaaS / commercial product to third parties.
  - Building a commercial product that substantially duplicates Flote.
- **After 2 years** (= 2028-05-27): the license **automatically converts to Apache License 2.0** via FSL's [future-grant clause](https://fsl.software/).

Full terms in [LICENSE.md](./LICENSE.md). "FSL-1.1-ALv2" is the official short name; it is identical to what is sometimes referred to as "FSL-1.1-Apache-2.0" (= ALv2 = Apache License Version 2.0).

### Why FSL?

- **MIT / Apache from day one**: can't prevent someone from re-skinning Flote and selling it as their own product.
- **AGPL**: tends to push away both consumer adoption and downstream contributors.
- **Fully closed source**: gives up the transparency / trust that matters for a solo-built indie tool.
- **FSL** sits in the middle: a 2-year protection window followed by automatic OSS conversion. That gives one solo developer the speed-of-indie advantage today and the community a guaranteed open future.

---

## Roadmap

### Phase 1 (= 2026-05, this release)
- Make this repository public under FSL-1.1-ALv2.
- Update the LP with the GitHub link, the free-beta narrative, and a placeholder waitlist input.
- Keep the app **free** with no end date for now.

### Phase 2 (= TBD, freemium-light under consideration)
- Once awareness crosses some threshold (= GitHub stars, DAU, or "Flote" actually getting indexed by AI search), evaluate a ~¥300 paid tier for **new** users.
- Grandfathering policy for existing free users is intentionally left undecided until Phase 2.
- Waitlist email actually wired up (= Loops / ConvertKit / Buttondown TBD).
- Apple Developer Program enrollment + proper signing & notarization.
- Flutter Windows build distribution.

### Phase 3+
- Cross-device settings sync (= multi-Mac, or Mac + Windows).
- Possible iOS companion (= will piggyback on Helix iOS's distribution path once that lands).

### A note on discoverability
- The LP currently ships with `robots.txt` + `X-Robots-Tag: noindex` (= see `website/vercel.json`).
- That's a Phase 1 choice: I don't want the LP indexed by AI search yet — I'd rather grow inside the Mac dev community by word of mouth first.
- "Open up discoverability" is a Phase 2 decision and will likely move in sync with the ¥300 tier timing above.

---

## Contributing

During Phase 1, this repository accepts **issues only**:

- Bug reports / feature requests / usability feedback → GitHub Issues are warmly welcome.
- Pull requests → **closed for the moment**. Once the license auto-converts to Apache 2.0 (= 2028-05-27), PR review will reopen.

Why:
- Phase 1 is when the brand voice and design intent get locked in.
- One solo developer can't sustain meaningful PR review bandwidth.
- After the Apache 2.0 conversion, forks + community-led development become natural.

Security-sensitive reports: please contact directly rather than opening a public issue.

---

## Acknowledgements

- **Flote is a Direct product.** Direct is the Mac-native tool portfolio that 荒井 知憲 (Tomonori Arai) builds and runs solo. Sibling product: [Helix](https://direct-homepage.vercel.app), a privacy-first Chromium fork browser.
- AI structuring uses [Claude](https://www.anthropic.com/claude) (Anthropic) and [Ollama](https://ollama.com) (local LLM runtime).
- Update delivery is powered by the [Sparkle](https://sparkle-project.org) framework.

---

## Links

- Website: https://flote-website.vercel.app
- Direct (= parent): https://direct-homepage.vercel.app
- Author: Tomonori Arai -- @TomArai85 on X
- License: [FSL-1.1-ALv2](./LICENSE.md)
- This README is the English derivative. Primary source: [日本語 README](./README.md).
