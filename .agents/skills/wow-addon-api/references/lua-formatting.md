# Lua Formatting

Apply these conventions whenever writing, editing, or formatting this addon's Lua files.
The target grammar is Lua 5.1. The root [.stylua.toml](../../../../.stylua.toml) configures the base formatter;
apply declaration layout and assignment alignment afterward.

## Research And Project Choices

Lua has no universal formatting standard. The [LuaRocks style guide](https://github.com/luarocks/lua-style-guide)
documents common conventions, but chooses three-space indentation and allows some one-line blocks.
This project instead keeps its existing four-space indentation and requires **all block bodies to be multiline**.
The following are project choices, not requirements of the Lua language:

- Four spaces per indentation level; no indentation tabs.
- One local binding per line; never pack several local names onto the same line.
- Preserve the codebase's CRLF line endings, keep a final newline, and remove trailing whitespace outside literals.
- A 120-column wrapping target. Do not split string contents to meet it.
- Spaces around binary operators and assignments; one space after commas.
- Vertically aligned `=` operators in consecutive table fields and related assignment groups.
- No space before a function's argument parentheses.
- Indent table fields and wrapped expressions consistently. Short data tables may stay inline.
- Preserve useful existing blank lines and comments; do not add explanatory comments during formatting.

Sources: [LuaRocks indentation and formatting](https://github.com/luarocks/lua-style-guide#indentation-and-formatting),
[spacing](https://github.com/luarocks/lua-style-guide#spacing),
[tables](https://github.com/luarocks/lua-style-guide#tables), and
[StyLua options](https://github.com/JohnnyMorganz/StyLua#options).

## Meaningful Variable Names

Every local, parameter, loop variable, and comparator operand must explain its role.
Never use placeholder names such as `i`, `j`, `k`, `u`, `_`, or opaque single-letter names such as `p`, `t`, or `f`.
Avoid cryptic abbreviations when a clear role name fits: use `scanState`, `playerRecord`, `query`, `editBox`,
`fontString`, or `nameplateFrame` rather than `ms`, `p`, `q`, `eb`, `fs`, or `np`.

- Use domain-specific indices and keys: `playerIndex`, `memberId`, `queryIndex`, `raceKey`, or `settingKey`.
- Name records and widgets by purpose: `guildData`, `member`, `replyRecord`, `pendingObservation`, or `inviteButton`.
- Name comparator operands for the values compared: `leftReply` and `rightReply`, not `a` and `b`.
- Name coordinates, color channels, counts, and units explicitly: `cursorX`, `cursorY`, `red`, `green`, `blue`,
    `processedUnitCount`, or `elapsedSeconds`.
- Unused loop, return, and callback positions still need meaningful API-role names. Do not delete positions,
    reuse anonymous placeholders, or change function arity just to avoid naming them.
- Established public namespace names such as `NS`, `UI`, and `ADDON` are meaningful contracts, not placeholders.
    Preserve public globals, namespace fields, table-property keys, strings, and SavedVariables schemas.

```lua
for playerIndex, playerRecord in ipairs(players) do
        Observe(playerRecord)
end

table.sort(replies, function(leftReply, rightReply)
        return leftReply.at < rightReply.at
end)
```

An explicitly requested naming cleanup is different from a whitespace-only formatting pass.
Rename each lexical binding and only its references, account for shadowing and closures, then compare compiled
Lua 5.1 instructions and constants before and after while excluding debug names and line metadata.
Do not use blind text replacement or change runtime table keys to match renamed locals.

Run the bundled [naming audit](../scripts/check_lua_names.py), using the same parser dependencies as the alignment helper:

```text
python .agents/skills/wow-addon-api/scripts/check_lua_names.py --self-test
python .agents/skills/wow-addon-api/scripts/check_lua_names.py
```

With no paths, it checks every Lua file in the addon; individual file or directory arguments limit its scope.
It checks declarations, parameters, loop bindings, and local functions rather than matching strings or field keys.
Single-letter and other opaque short bindings are rejected except established public `NS`, `UI`, and `ADDON` names.
The audit catches common placeholders; review longer names for meaning rather than treating a passing check as enough.

## Local Declarations

Declare independent values with separate `local` statements, each on its own line. Keep related initializers
vertically aligned using the assignment rules below.

```lua
local seen     = {}
local good     = {}
local allSeen  = 0
local allGood  = 0
```

When a declaration receives multiple returns from one function call or `...`, retain a shared declaration
with exactly one binding per line and one evaluation of its initializer:

```lua
local class,
    classFile = UnitClass(unitToken)

local ADDON,
    NS = ...
```

Use the same shared layout when separate declarations would change name resolution, evaluation order, or the
number of function results. Lua activates all locals in a declaration together, after evaluating its initializer;
naively splitting it can make a later initializer read a newly declared local instead of the original outer value.
Never duplicate API calls, use `select` to re-call them, pack returns into temporary tables, add temporary bindings,
or predeclare locals before an initializer just to force separate `local` keywords.
For uninitialized locals, separate `local` statements are safe unless they affect a recursive function binding.

StyLua normally joins shared declarations. Apply the Lua-aware declaration-layout step after the base formatter
and before assignment alignment, and verify the combined workflow rather than relying on raw StyLua output alone.
Use the bundled [declaration-layout helper](../scripts/split_lua_locals.py), which uses the existing parser dependencies:

```text
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py --self-test
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py --check
```

It checks every addon Lua file by default, accepts file or directory arguments to limit scope, and reapplies
assignment alignment after laying out declarations. `--check` makes no edits and fails if two local bindings share a line.
Keep generic-loop variable lists and function parameter lists unchanged; they are not local declaration statements.
See the [Lua 5.1 local declarations](https://www.lua.org/manual/5.1/manual.html#2.4.7)
and [scope rules](https://www.lua.org/manual/5.1/manual.html#2.6).

## Aligned Assignments

Align `=` vertically across each consecutive group of named or bracket-keyed fields in a multiline table.
Use at least two spaces before `=` on the longest left-hand side and one space after it.
Apply the same rule to consecutive assignment statements or consecutive initialized local declarations
at the same indentation and in the same scope.

```lua
local scanState = {
    queries   = {},
    index     = 0,
    found     = 0,
    running   = false,
    awaiting  = false,
    paused    = false,
    sentAt    = 0,
    record    = false,
    tally     = {},
    open      = {},
    width     = LEVEL_STEP,
}

player.class      = info.class or player.class
player.classFile  = info.classFile or player.classFile
player.race       = info.race or player.race
```

- Align each nested table independently. Leave compact inline tables unchanged.
- Reset groups at blank lines, standalone comments, non-assignment statements, scope changes, or different indentation.
- A multiline value ends its group; its first-line `=` can align with the preceding group, but never align
    fields or statements inside that value with the outer group.
- Require at least two assignments for a group; keep isolated assignments at normal single-space spacing.
- Do not add padding inside strings, comments, bracket-key expressions, or values. Keep comment text unchanged;
    trailing comments do not need their own alignment column.
- Do not add wrapping or exceed the 120-column code target solely for alignment. Split alignment groups around rows
    that would become too long. Exclude trailing comments from this width check and leave their text intact.

This is a project-specific readability rule. StyLua's documented configuration has no assignment-alignment option,
so alignment must be a separate, Lua-aware whitespace pass rather than an unsupported TOML setting.

## Always-Multiline Blocks

Put the body after `then`, `else`, or `do` on a new, indented line. Put closing `end` on its own line.
Apply this even to a single `return`, `break`, assignment, or function call.
Keep `elseif condition then` together as a branch header; never rewrite it as nested `else` / `if`.

```lua
if not player then
    return
elseif player.guild == "" then
    Queue(player)
else
    Remember(player)
end

for playerIndex, player in ipairs(players) do
    Observe(player)
end

while pending do
    Process()
end

repeat
    Process()
until done

local function IsReady()
    return ready
end

frame:SetScript("OnClick", function()
    Refresh()
end)
```

Function definitions and callbacks follow the same rule: the body starts after the parameter list on a new line.
Separate consecutive statements onto individual lines. Preserve the order of every statement.
The same layout applies to `do` blocks and empty blocks; do not insert comments or executable statements to fill them.

## Formatter

Use [StyLua](https://github.com/JohnnyMorganz/StyLua), pinned to 2.6.0 for this formatting pass, with Lua51 syntax.
The configuration disables require sorting, preserves call-parenthesis style, and sets
`collapse_simple_statement = "Never"`.

```text
stylua --config-path .stylua.toml --verify <Lua files>
stylua --config-path .stylua.toml --check <Lua files>
```

Finish with the bundled [alignment helper](../scripts/align_lua.py). Run it on its own for alignment-only edits.
It requires Python 3.11 or newer and the parser versions in [requirements.txt](../scripts/requirements.txt).
From the addon root:

```text
python -m pip install -r .agents/skills/wow-addon-api/scripts/requirements.txt
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py --self-test
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py
python .agents/skills/wow-addon-api/scripts/split_lua_locals.py --check
python .agents/skills/wow-addon-api/scripts/align_lua.py --self-test
python .agents/skills/wow-addon-api/scripts/align_lua.py
python .agents/skills/wow-addon-api/scripts/align_lua.py --check
```

With no paths, the helper checks every Lua file beneath the addon root. Supply individual Lua files or directories
to limit the pass. It reads `column_width` from `.stylua.toml`, preserves existing line endings and token text,
and fails rather than modifying code with parse errors. `--check` makes no edits and exits nonzero if alignment is needed.
The complete order is base formatting, declaration layout, then assignment alignment.
Re-run the helpers after StyLua, since the base formatter joins shared declarations and removes alignment padding.

Known limitations:

- `column_width` is an approximate wrapping target, not an absolute maximum.
- No quote-style option preserves every original string spelling. `AutoPreferDouble` can change delimiters or escapes.
- StyLua may adjust expression parentheses and table punctuation. Do not assume that parsing alone proves safety.
- For formatting-only passes, use its output as a whitespace-layout proposal and retain the original executable
    tokens, literal spellings, and comments. Check that this combined process is idempotent; a raw `--check` can still
    suggest punctuation or quote changes that are intentionally excluded.
- Comment-free empty functions can still collapse under `Never`. Expand these with a whitespace-only adjustment
  after formatting if any exist; the project's multiline rule takes precedence over formatter output.
- `--verify` compares normalized ASTs. Upstream explicitly documents possible false positives and false negatives.

Sources: [StyLua configuration and verification](https://github.com/JohnnyMorganz/StyLua),
[collapse handling](https://github.com/JohnnyMorganz/StyLua/blob/main/src/context.rs), and
[AST verification implementation](https://github.com/JohnnyMorganz/StyLua/blob/main/src/verify_ast.rs).

## Formatting-Only Safety

1. Capture the actual working files before formatting, not just the committed versions. Preserve existing user edits.
2. Run a Lua-aware formatter, not regular-expression substitutions over unparsed source.
3. Preserve identifiers, strings and their runtime values, numbers, comments, operators, statement order,
   scopes, callbacks, event registrations, table field order, and evaluation order.
4. Do not simplify conditions, rename variables, move functions, sort tables, remove code, or apply optimizations.
5. Run StyLua `--verify` and compile every file with a real Lua 5.1 parser.
6. For a whole-codebase pass, compare compiled function prototypes before and after: instructions, constants,
   parameters, stack sizes, upvalues, and nested prototypes must match. Exclude only source names and debug metadata
   such as line numbers and local-variable locations, which necessarily move when formatting changes.
7. Check comments, token-preserving formatter-plus-layout-and-alignment idempotence, and the multiline layout before finishing. If a formatter changes
   executable tokens, retain the original tokens and apply only its whitespace layout, then revalidate.

An explicitly requested declaration split adds `local` keywords and moves initializer expressions between statements.
Check exact identifier, literal, and comment contents separately from the altered declaration punctuation;
require unchanged compiled Lua 5.1 executable prototypes and one local binding per declaration line.

Lua is largely free-format, but whitespace inside strings is data, comments end at newlines, and parentheses can
change multiple-return behavior. Never remove whitespace blindly when checking equivalence.
See the [Lua 5.1 lexical conventions](https://www.lua.org/manual/5.1/manual.html#2.1),
[expressions](https://www.lua.org/manual/5.1/manual.html#2.5), and
[function calls](https://www.lua.org/manual/5.1/manual.html#2.5.8).