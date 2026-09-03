# Assistant feature copy — release evidence

The expanded product page describes the published macOS v0.10.25 / build 78
feature set and iOS v0.1.35 / build 57 companion. Features were checked against
release-pinned project documentation and source, rather than advertised from
roadmaps or old issue lists.

| Website topic | Evidence | Qualification retained in the copy |
| --- | --- | --- |
| Project-free chat and text export | [README: product previews](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/README.md#product-previews) | Native Save panel exports generated text; no unsupported office-file claim |
| Web research and image understanding | [README: TinyFish](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/README.md#optional-tinyfish-web-search), v0.3 vision section | TinyFish needs the user's key; image understanding needs a vision-capable provider |
| MLX, GGUF, model recommendations | [README: models](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/README.md#models) | GGUF needs llama.cpp; no unverified speed or memory claims |
| Providers and compatible endpoints | README v0.8.4 provider interoperability | User-supplied keys; remote requests go to the selected service |
| ChatGPT account models | [CodexAppServer.swift](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/Core/OpenAI/CodexAppServer.swift), README v0.9.0 | Requires local Codex and eligible account access; no claim of included API credits |
| Imported chats and portable task bundles | README v0.8 and v0.8.6 | Imports conversation history, not another agent's live process; task bundles require a passphrase |
| Project intelligence and memory | [README: Workspace Intelligence](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/README.md#workspace-intelligence), v0.3 memory | Project features are described in Code mode; memory is optional |
| Plans, approvals, checkpoints, verification | README v0.2, v0.4, v0.8.5 and Agent safety | Default approval behavior allows configured rules; verification is opt-in |
| Skills, MCP and OpenCode imports | README v0.9.4 and v0.8.4 | Declarative skill discovery; JavaScript-only middleware may need a gateway |
| Four specialist bots and workflow roles | [BotWorkflow.swift](https://github.com/Mesutcydev/vamp-assistant/blob/v0.10.25/Core/BotComputers/BotWorkflow.swift) | Each role has a distinct task; no guarantee every workflow uses every bot |
| Bot browsers, Queue/Steer, optional computers | README v0.10.7 and v0.10.10 | Bot computers are optional; Linux micro-VMs need the container runtime |
| Browser and Simulator | README v0.3, v0.4 and v0.6 | Existing real screenshots retained; no new synthetic UI claims |
| Ship Center | README v0.9.4 | Signing, connected-device installation, and upload need valid local tooling and credentials |
| Local API and CLI | README v0.5 | Same-Mac loopback service, not a public hosted API |
| Mobile workspace, model and bot controls | README v0.10.9, v0.10.10 and v0.10.25 | Mac remains the execution host; native companion capabilities are separate from the browser remote |
| App/display control, sharing, remote unlock | README v0.10.5 and v0.10.25 | Permissions apply; unlock needs host opt-in and authenticated Tailscale |

Presentation: first-screen homepage discovery link and a stronger independent
Assistant showcase; grouped feature sections with a jump index on its own
page; full English and Turkish copy. Sync installation remains a separate path.
