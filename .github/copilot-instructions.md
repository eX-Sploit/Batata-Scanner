# Batata Scanner Copilot instructions

Read [AGENTS.md](../AGENTS.md) before making changes. It is the shared contributor policy for both Copilot and Codex.

This is a standalone WoW Forever census addon, targeting Interface 16001. Use the repository's [API baseline](../skills/wow-addon-api/SKILL.md) for Lua changes, then the focused [social](../skills/wow-forever-social/SKILL.md), [UI](../skills/wow-forever-ui/SKILL.md), or [workflow](../skills/wow-forever-workflow/SKILL.md) skill as appropriate. Discoverable wrappers under `.github/skills/` link to those canonical files.

Keep `Batata_Scanner_DB` account-wide and owned internally. Expose only the documented copy-returning [fetch/filter API](../docs/API.md). Do not add mutation or scan-control methods to the public API. Do not alter another addon or import GuildHQ data. Follow the TOC release policy and [Lua conventions](../skills/wow-addon-api/references/lua-formatting.md). Use the focused [pinned research](../docs/wow-forever-api/README.md) without mistaking it for a current-client test. Report mocks and in-game verification separately.
