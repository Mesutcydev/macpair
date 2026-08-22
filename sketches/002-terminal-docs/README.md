## Variant: Terminal / docs

### Design stance
The site IS the documentation: mono-font terminal hero, then a dense release table listing every component + version + download button, then docs-style sections with a sticky sidebar.

### Key choices
- Layout: terminal hero → component download table (rows) → sticky-sidebar docs (quickstart, which host, safari, cli, agents, security)
- Typography: monospace for headings and UI accents, green-on-black terminal palette
- Color: dark forest/terminal green (#4ade80)
- Interaction: release.json-driven table, blinking cursor, theme toggle

### Trade-offs
- Strong at: information density, developer credibility, the download table maps 1:1 to release.json assets
- Weak at: less visual warmth, screenshots absent, can read as "docs page" rather than product page

### Best for
- An audience of developers who want the file and the command, immediately.
