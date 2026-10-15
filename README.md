# libdiscord documentation

Project version 0.8.0. Native library 0.6.2, Lua package 0.2.0.

libdiscord is a Lua library for the Growtopia/Bothax executor. It provides a Discord bot (Gateway v10 and REST), a WebSocket client, and HTTP/HTTPS. The networking is written in C (Lua 5.4.8 statically linked). On top of it sits a Lua package with an API modeled on discord.js: builders, a `Client`, and the same payload shapes.

Contents:
1. [How it works](#1-how-it-works)
2. [Installation](#2-installation)
3. [Quick start](#3-quick-start)
4. [Client](#4-client)
5. [Context (`ctx`)](#5-context-ctx)
6. [Message payloads](#6-message-payloads)
7. [Builders](#7-builders)
8. [Native API](#8-native-api)
9. [JSON](#9-json)
10. [Limits](#10-limits)
11. [Troubleshooting](#11-troubleshooting)
12. [Security](#12-security)
13. [Build and test](#13-build-and-test)

---

## 1. How it works

- One C thread handles all networking (Gateway, REST). That thread never touches the `lua_State`.
- Events go into a queue. The queue is drained on the game thread by an `OnDraw` hook that is installed automatically (at most 50 events or about 3 ms per frame). The bot only processes events while the game is drawing frames.
- There are no Promises or `await`. Everything is asynchronous through events and handlers.
- There is no Guild, Channel or Message cache. Handlers receive plain tables.
- REST uses a single keep-alive HTTPS connection that is reused, with one serial queue.

Two layers:

| Layer | Files | Contents |
|---|---|---|
| Native | `libdiscord.so` | `discord.bot`, `discord.connect`, `discord.request`, `discord.json_decode`, `discord.now` |
| Lua package | `init.lua`, `builders.lua`, `json.lua` | `discord.Client`, all builders, `discord.json.encode` |

`require('discord')` loads `init.lua`, which calls `package.loadlib` on `libdiscord.so` and merges it with the builders and the `Client`.

Note: the library's built-in messages (validation errors, the error reply sent when a handler fails, console log lines) are currently written in Indonesian.

## 2. Installation

Requirements: Android aarch64 or Linux, and Lua 5.4.8. The executor's Lua version must match the one linked into the `.so`. Lua 5.1, 5.2, 5.3 and LuaJIT are not supported.

### 2.1 Manual

1. Build `libdiscord.so` in Termux (see [Build and test](#13-build-and-test)).
2. Copy the `.so` to `Android/media/com.rtsoft.growtopia/`, then run `tools/install_lib.lua` from Bothax. That script copies the file to `/data/data/com.rtsoft.growtopia/libdiscord.so` through a temporary `.new` file and `os.rename`.
3. Copy the `lua/discord/` folder to `Android/media/com.rtsoft.growtopia/scripts/discord/`.
4. In your script:

```lua
local DIR = '/storage/emulated/0/Android/media/com.rtsoft.growtopia/scripts/'
DISCORD_LIB = '/data/data/com.rtsoft.growtopia/libdiscord.so'   -- default; change if it lives elsewhere
package.path = DIR .. '?.lua;' .. DIR .. '?/init.lua;' .. package.path
local discord = require('discord')
```

A library that is already loaded cannot be replaced until the game is closed. After replacing the `.so`, fully close the game and open it again.

### 2.2 From GitHub (`kazloader_v0.8.0.lua`)

The loader downloads `libdiscord.so` (if it is missing) and the three Lua files straight from GitHub with `MakeRequest`. The Lua files are loaded into memory through `package.preload` and are not saved to disk.

Fill in the config section at the top of the file:

| Variable | Meaning |
|---|---|
| `USER`, `REPO` | GitHub account and repository |
| `REF` | `'refs/heads/main'` (branch), `'refs/tags/v0.8.0'` (tag), or a commit hash |
| `PATH` | folder of the Lua files in the repo (`''` for the repo root) |
| `LIB_FILE` | location of the `.so` in the repo |
| `LIB` | where the `.so` is installed on the device |
| `UPDATE_LIB` | `true` = download the `.so` again even if it exists |
| `EXPECT_SIZE` | size of the `.so` on GitHub in bytes; setting it detects truncated downloads |

The `.so` is checked (`ELF` header, size) before it is written. It is written to a temporary file and then renamed.

Use a tag or commit hash for `REF`, not a branch, because a branch can change. Downloaded code runs inside the game and can read the bot token. Use your own repository.

## 3. Quick start

```lua
local discord = require('discord')
local client  = discord.Client('BOT_TOKEN', { intents = 0 })   -- slash-only: no privileged intents

client:slash(
  discord.SlashCommandBuilder():setName('say'):setDescription('Send a chat message')
    :addStringOption { name = 'text', description = 'Message text', required = true, max_length = 120 },
  function(ctx)
    ctx:reply(discord.EmbedBuilder():setTitle('Sent'):setDescription(ctx.options.text), { ephemeral = true })
  end)
```

Call `discord.Client` and `client:slash` from the body of the main script, not from inside `RunThread`. Global commands can take a few minutes to appear in Discord.

Comparison with discord.js:

| discord.js | libdiscord |
|---|---|
| `new Client({intents})` + `login(token)` | `discord.Client(token, {intents=})` |
| `client.on('messageCreate')` / `'interactionCreate'` | `client:on('message')` / `client:on('interaction')` |
| manual `commandName` check | `client:slash(builder, fn)` (automatic routing) |
| `interaction.options.getString('x')` | `ctx.options.x` |
| `interaction.reply({...})` | `ctx:reply(payload, {ephemeral=})` |
| `deferReply()` / `editReply()` | `ctx:defer()` / `ctx:edit()` |
| `followUp` | not available |
| `interaction.update()` / `deferUpdate()` / `showModal()` | `ctx:update()` / `ctx:deferUpdate()` / `ctx:showModal()` |
| `fields.getTextInputValue()` | `ctx.fields:getTextInputValue()` (nil if missing) |
| collectors or manual `customId` checks | `client:button`, `client:select`, `client:modal` |
| `channel.send()` | `client:send(channel_id, payload)` |

## 4. Client

### `discord.Client(token [, opts]) -> client | nil, err`

`opts` is the same as for `discord.bot`: `intents`, `ignore_bots`, `gateway`, `api`, `ca`, `insecure` (see [Native API](#8-native-api)). For a slash-only bot use `{ intents = 0 }`.

### Methods

| Method | Purpose |
|---|---|
| `client:slash(builder, fn)` | Register a global slash command and route it to `fn(ctx)`. |
| `client:button(id, fn)` | Button handler. |
| `client:select(id, fn)` | Select menu handler. `ctx.values` holds the chosen values as an array. |
| `client:modal(id, fn)` | Modal submit handler. `ctx.fields` holds the inputs. |
| `client:autocomplete(command, fn)` | Autocomplete handler for a command. |
| `client:on(event, fn)` | Event listener. Several listeners per event are allowed; `'*'` matches all events. |
| `client:send(channel_id, payload [, tag])` | Send a message to a channel. |
| `client:presence`, `ping`, `status`, `rest`, `close`, `command`, ... | Forwarded to the native bot object. |

The `id` for `button`, `select` and `modal` can be exact (`'vote:1'`) or end with `*` (`'vote:*'`) to match every id with that prefix. If several prefixes match, the longest one wins. `ctx.customId` always holds the full id. Interactions with no handler are ignored.

### Handlers

- A handler that returns a payload (string, `EmbedBuilder`, table, `ComponentsV2(...)`) replies automatically, as long as no reply has been sent yet.
- For autocomplete, the return value is used as the list of choices.
- An error in a handler is logged to the console and the bot keeps running. The user receives a private error reply. For autocomplete the answer is an empty list. After `deferUpdate`, the error is only logged.
- An error in a `client:on` listener is logged and does not stop the other listeners.

### Events

`client:on(name, fn)` accepts: `message`, `ready`, `status`, `interaction`, `rest_response`, `rest_error`. The fields of each are listed under [Native events](#events-boton-event-fn-or-botpoll).

The `ready` event sets `client.app_id`, which `ctx:edit` needs for non-string payloads.

### `client:send(channel_id, payload [, tag])`

`payload` can be a string (1..2000 characters), an `EmbedBuilder`, a table, or `ComponentsV2(...)`. `channel_id` must be a numeric string. Automatic mentions are disabled.

## 5. Context (`ctx`)

One object per interaction.

### Fields

| Field | Contents |
|---|---|
| `ctx.options` | `{name = value}` table for slash commands (string, number or boolean). |
| `ctx.sub` | Subcommand name, if any. |
| `ctx.user_id`, `ctx.user` | The user who triggered the interaction. |
| `ctx.channel_id`, `ctx.guild_id` | Where the interaction happened. |
| `ctx.customId` | Full id of the component or modal. |
| `ctx.componentType` | 2 button, 3/5/6/7/8 select menus. |
| `ctx.message_id` | The message the component is on. |
| `ctx.values` | Array of selected values (select menus). |
| `ctx.fields` | Modal inputs. `ctx.fields:getTextInputValue(id)` returns `nil` if missing. Select values inside a modal are in `ctx.fields.values[id]` (an array). |
| `ctx.focused` | `{name=, value=}` for autocomplete. |
| `ctx.interaction_type` | 2 slash, 3 component, 4 autocomplete, 5 modal submit. |

### Methods

| Method | Interaction types | Purpose |
|---|---|---|
| `ctx:reply(payload [, {ephemeral=true}])` | slash, component, modal | Reply (callback type 4). |
| `ctx:defer([ephemeral])` | slash | Defer the reply; continue with `ctx:edit`. |
| `ctx:edit(payload)` | after reply or defer | Edit the original reply. After `deferUpdate` it edits the source message. |
| `ctx:update(payload)` | component, modal | Edit the message the component is on (type 7). |
| `ctx:deferUpdate()` | component, modal | Acknowledge without changing anything (type 6). |
| `ctx:showModal(modal)` | slash, component | Show a form (type 9). |
| `ctx:respond(choices)` | autocomplete | Answer an autocomplete (type 8). |

Calling a method on the wrong interaction type raises a clear Lua error. `ctx:update` from a modal submit is only accepted by Discord when the modal was opened from a message component (Discord behavior, not yet tested on a device).

`ctx:respond(choices)`: at most 25 choices. Each choice is a string, a number, or `{name=, value=}` (name 1..100 characters, value a number or a string of at most 100 characters).

Discord requires the first response within 3 seconds. For longer work, call `ctx:defer()` first, then `ctx:edit(...)`.

## 6. Message payloads

`ctx:reply`, `ctx:update`, `ctx:edit` and `client:send` accept:

| Form | Result |
|---|---|
| string | Plain text (`content`). |
| `EmbedBuilder` | A single embed. |
| table `{content=, embeds={...}, components={...}, flags=, ephemeral=true}` | Full payload. |
| `ComponentsV2(...)` | A Components V2 message. |

Rules that are validated:
- `content` is at most 2000 characters, and a message has at most 10 `embeds`.
- `ephemeral = true` adds flag 64 (visible only to the user who triggered it).
- A Components V2 message (flag 32768) cannot use `content` or `embeds`.
- `allowed_mentions` is empty by default, so no automatic mentions are sent.

Constants: `discord.MessageFlags = { Ephemeral = 64, IsComponentsV2 = 32768 }`.

## 7. Builders

All builders are fluent (methods return `self`), can be called as `Class()` or `Class.new()`, and have `toJSON()`. Discord limits are validated while building, so mistakes show up as Lua errors with a clear message instead of a 400 from REST.

### 7.1 SlashCommandBuilder

```lua
discord.SlashCommandBuilder()
  :setName('world')              -- 1..32, lowercase a-z, digits, _ and -
  :setDescription('World info')  -- 1..100
  :addStringOption { name = 'name', description = '...', required = true, max_length = 23 }
```

| Method | Notes |
|---|---|
| `setName(v)`, `setDescription(v)` | Required. |
| `addStringOption(spec)` | Also `addIntegerOption`, `addNumberOption`, `addBooleanOption`, `addUserOption`, `addChannelOption`, `addRoleOption`. |
| `addSubcommand(spec)` | `spec` is a `function(sub)` or a `SlashCommandSubcommandBuilder`. Cannot be mixed with options. |

Option `spec`: a table with the keys `name`, `description`, `required`, `min_value`, `max_value` (integer and number), `min_length`, `max_length` (string), `choices` (array of `{name=, value=}`, at most 25), or a `function(opt)` that uses `setName`, `setDescription`, `setRequired`, `setMinValue`, `setMaxValue`, `setMinLength`, `setMaxLength`, `addChoices`.

Rules: at most 25 options or subcommands, required options must come before optional ones, and option names must be unique.

### 7.2 EmbedBuilder

| Method | Limit |
|---|---|
| `setTitle(v)` | 1..256 |
| `setDescription(v)` | 1..4096 |
| `setURL(url)` | must start with `http://` or `https://` |
| `setColor(c)` | number 0..0xFFFFFF or `'#RRGGBB'` |
| `setTimestamp([t])` | epoch seconds or ISO string; empty = now |
| `setFooter(text [, iconURL])` or `setFooter{text=, iconURL=}` | text 1..2048 |
| `setAuthor(name [, iconURL [, url]])` or table | name 1..256 |
| `setThumbnail(url)`, `setImage(url)` | |
| `addFields({name=, value=, inline=}, ...)` | at most 25 fields, name 1..256, value 1..1024 |

The total embed text is at most 6000 characters.

### 7.3 Components V2

A V2 message is built with `discord.ComponentsV2(c1, c2, ...)`, which returns the payload `{flags = 32768, components = {...}}` for `ctx:reply`, `ctx:update` or `client:send`. A plain string becomes a `TextDisplay`. Validation: at most 40 components (including nested ones) and 4000 characters of text in total.

**ContainerBuilder**

| Method | Purpose |
|---|---|
| `setAccentColor(c)` | Color of the side bar. |
| `setSpoiler(b)` | Hide as a spoiler. |
| `addTextDisplay(text)` | Add text (string or `TextDisplayBuilder`). |
| `addSeparator([divider [, spacing]])` | `divider` defaults to `true`; `spacing` is 1 or 2. |
| `addSection(spec)` | `function(section)` or `SectionBuilder`. |
| `addMediaGallery(...)` | URLs, item tables, `function(gallery)`, or `MediaGalleryBuilder`. |
| `addActionRow(spec)` | `function(row)` or `ActionRowBuilder`. |
| `add(component)` | Add any component. |

A container needs at least 1 component.

**TextDisplayBuilder**: `setContent(v)`, 1..4000 characters. Supports Discord markdown.

**SeparatorBuilder**: `setDivider(b)`, `setSpacing(1|2)`.

**SectionBuilder**: 1..3 texts through `addTextDisplays(...)`, plus one accessory:
- `setThumbnailAccessory(url | ThumbnailBuilder)`
- `setLinkButtonAccessory(label, url)`
- `setButtonAccessory(button)` (any button, including interactive ones)

**ThumbnailBuilder**: `setURL`, `setDescription` (1..1024), `setSpoiler`.

**MediaGalleryBuilder**: `addItems(...)`, at most 10 items, each a URL or `{url=, description=, spoiler=}`.

Example:

```lua
local c = discord.ContainerBuilder():setAccentColor(0x4F545C)
  :addTextDisplay('## Status')
  :addSeparator()
  :addTextDisplay('World: START')
  :addActionRow(function(row)
    return row:addComponents(discord.ButtonBuilder():setCustomId('refresh'):setLabel('Refresh'):setStyle(discord.ButtonStyle.Primary))
  end)
ctx:reply(discord.ComponentsV2(c))
```

### 7.4 Interactive components

Constants: `discord.ButtonStyle = { Primary = 1, Secondary = 2, Success = 3, Danger = 4, Link = 5 }`, `discord.TextInputStyle = { Short = 1, Paragraph = 2 }`.

**ButtonBuilder**

| Method | Notes |
|---|---|
| `setCustomId(id)` | 1..100 characters. Required for non-link buttons. |
| `setLabel(v)` | 1..80 characters. |
| `setStyle(n)` | 1..5. |
| `setURL(url)` | Makes it a link button (style 5); a link button cannot have a `custom_id`. |
| `setEmoji(e)` | Unicode string or `{name=, id=, animated=}`. |
| `setDisabled([b])` | |

A button needs a label or an emoji. `ButtonBuilder.link(label, url)` creates a link button directly.

**ActionRowBuilder**: `addComponents(...)` (at most 5 buttons), `addLinkButton(label, url)`. A select menu must be alone in its row.

**StringSelectMenuBuilder** (also `UserSelectMenuBuilder`, `RoleSelectMenuBuilder`, `MentionableSelectMenuBuilder`, `ChannelSelectMenuBuilder`): `setCustomId`, `setPlaceholder` (1..150), `setMinValues` (0..25), `setMaxValues` (1..25), `setDisabled`. String menus only: `addOptions(...)` (at most 25) takes `{label=, value=, description=, emoji=, default=}` or a `StringSelectMenuOptionBuilder`, with label and value 1..100 characters. `ChannelSelectMenuBuilder` also has `setChannelTypes(...)`.

**TextInputBuilder** (modals only): `setCustomId`, `setLabel` (1..45), `setStyle`, `setPlaceholder` (1..100), `setValue` (1..4000), `setRequired`, `setMinLength`, `setMaxLength`.

**ModalBuilder**: `setCustomId`, `setTitle` (1..45), `addComponents(...)` (at most 5 rows). A `TextInputBuilder` can be passed directly and is wrapped in an `ActionRow` automatically.

Full flow example:

```lua
client:slash(discord.SlashCommandBuilder():setName('menu'):setDescription('Example'), function(ctx)
  return { content = 'Choose:', components = {
    discord.ActionRowBuilder():addComponents(
      discord.ButtonBuilder():setCustomId('vote:1'):setLabel('Vote'):setStyle(discord.ButtonStyle.Primary),
      discord.ButtonBuilder():setLabel('Docs'):setURL('https://example.com')),
    discord.ActionRowBuilder():addComponents(
      discord.StringSelectMenuBuilder():setCustomId('pick'):setPlaceholder('Choose')
        :addOptions({ label = 'A', value = 'a' }, { label = 'B', value = 'b' })) } }
end)

client:button('vote:*', function(ctx) return ctx:update('pressed: ' .. ctx.customId) end)

client:select('pick', function(ctx)
  ctx:showModal(discord.ModalBuilder():setCustomId('form'):setTitle('Form'):addComponents(
    discord.TextInputBuilder():setCustomId('name'):setLabel('Name'):setStyle(discord.TextInputStyle.Short)))
end)

client:modal('form', function(ctx)
  return { content = 'hello ' .. ctx.fields:getTextInputValue('name'), ephemeral = true }
end)

client:autocomplete('say', function(ctx) return { ctx.focused.value .. '1', ctx.focused.value .. '2' } end)
```

## 8. Native API

Use this directly when you do not use the Lua package.

```lua
local discord = package.loadlib('/data/data/com.rtsoft.growtopia/libdiscord.so', 'luaopen_discord')()
local bot = discord.bot('BOT_TOKEN')
bot:command('world', 'current world info')
bot:on('interaction', function(ev)
  if ev.name == 'world' then bot:reply(ev, 'World: ' .. GetWorld().name) end
end)
```

### Library information

`discord.version` (string, for example `'0.6.2'`), `discord.tls` (boolean), `discord.now()` (monotonic clock in ms, for measuring latency).

### `discord.bot(token [, opts]) -> bot | nil, err`

| Option | Meaning |
|---|---|
| `intents` | Default 33281 (Guilds, GuildMessages, MessageContent). Add 4096 for DMs. Slash-only: 0. |
| `ignore_bots` | Default `true`. |
| `gateway`, `api` | Replacement URLs, for local testing. |
| `ca` | CA file or folder. |
| `insecure` | No certificate verification. For local testing only. |

### Events: `bot:on(event, fn)` or `bot:poll()`

Use `on` or `poll`, not both. `on` installs `AddHook('OnDraw', ...)` automatically and must be called from the body of the main script. `'*'` matches all events. Every event has a field `t` (`discord.now()` when it entered the queue).

| Event | Fields |
|---|---|
| `message` | `id`, `channel_id`, `guild_id`, `author_id`, `author`, `content` |
| `ready` | `user_id`, `username`, `session`, `app_id` |
| `status` | `state` (`connecting`, `connected`, `reconnecting`, `fatal`, `stopped`), `code`, `text` |
| `interaction` | `interaction_type`, `id`, `token`, `channel_id`, `guild_id`, `user_id`, `user`. Slash and autocomplete: `name`, `sub`, `options`; autocomplete also `focused`. Components: `custom_id`, `component_type`, `message_id`, `data` (raw JSON). Modals: `custom_id`, `data`. |
| `rest_response` | `status`, `body`, `tag`, `queued`, `ms` (only successful tagged requests) |
| `rest_error` | `status`, `text`, `tag`, `queued`, `ms` |

`queued` is how long the request waited in the queue, `ms` is the duration of the HTTP request.

A `status` event with `fatal` and code `4004` means the token is wrong or the intents are not allowed.

### Actions

| Method | Purpose |
|---|---|
| `bot:send(channel_id, text [, tag])` | Send text, 1..2000 characters. |
| `bot:rest(method, path, json_body [, tag])` | GET/POST/PUT/PATCH/DELETE against the Discord REST API. |
| `bot:presence(status [, text [, type]])` | `online`, `idle`, `dnd`, `invisible`; type 0, 2, 3 or 5. |
| `bot:command(name, description [, options_json])` | Register a global slash command; allowed before `ready`. |
| `bot:reply(ev, text [, ephemeral])` | Reply to a slash command (within 3 seconds). |
| `bot:defer(ev [, ephemeral])`, `bot:edit(ev, text)` | Defer and edit the reply. |
| `bot:ping()` | Last Gateway heartbeat RTT in ms, or `nil`. |
| `bot:status()` | State and last close code. |
| `bot:close()` | Stop the thread and remove the hook. |

### Low level

`discord.connect(url [, opts])` opens a WebSocket (`ws`/`wss`) with `send`, `recv`, `isopen`, `close`. `discord.request(...)` performs asynchronous HTTP/HTTPS. Usage examples are in `test.lua`, `test_tls.lua` and `test_http.lua`.

## 9. JSON

`discord.json.encode(table)` is a pure Lua encoder. `discord.json.array(t)` marks a table as an array (useful for empty arrays, since an empty table is encoded as an object).

`discord.json_decode(str) -> value | nil, err` is the native decoder:
- Objects and arrays become tables. Strings become UTF-8 strings (`\uXXXX` and surrogate pairs are decoded).
- Whole numbers become integers, anything else a float.
- `null` becomes `nil`: object fields are dropped, and `#t` is unreliable when an array contains `null`.
- Empty objects and empty arrays both become an empty table. For duplicate keys the last one wins.
- It is strict: trailing data after the value, trailing commas, numbers such as `01`, `1.` or `+1`, and nesting deeper than 200 are rejected (it returns `nil` and a message with the position, and does not crash).

```lua
local d, err = discord.json_decode(ev.body)
if d then print(d.id, d.username) else print('invalid JSON: ' .. err) end
```

## 10. Limits

Library limits:
- POSIX only (Android or Linux).
- Not implemented: reaction, member and voice events, file uploads, guild cache, sharding, zlib compression, per-bucket rate limiting (one serial queue), `followUp`, premium buttons, the newer modal `Label` component, and the File, File Upload, Radio Group and Checkbox components. Modals still use an Action Row containing a Text Input, which Discord's documentation now marks as deprecated but which still works.
- The Lua version must match the executor's Lua.
- The bot only processes events while `OnDraw` is being called.

Discord limits validated by the builders are listed in each part of [Builders](#7-builders). A limit that could not be confirmed from the official documentation (4000 characters of total text in a V2 message) is applied as a conservative cap.

## 11. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `libdiscord: tidak bisa memuat ...` (cannot load the library) | The `.so` is not at the path, the architecture is wrong, or the Lua version does not match. Check `DISCORD_LIB` and rebuild with the same `LUA_VER` as the executor. |
| Old version still active after replacing the `.so` | The old library is still loaded. Fully close the game, then open it again. |
| Loader: `status 404` | Wrong `USER`, `REPO`, `REF` or file name; private repo; tag not created. Open the raw URL in a browser to check. |
| Loader: `.so` is not a valid file | The response was not binary (for example an HTML page). Check `LIB_FILE`. |
| Loader: size mismatch | Truncated download. Try again or use `install_lib.lua`. |
| Command does not appear in Discord | Global commands take time. Check that the status is `connected`. |
| `status fatal 4004` | Wrong token, or intents not allowed. |
| Bot does not respond | `OnDraw` is not running (game minimized), or the `Client` was created inside `RunThread`. |
| `Interaction failed` in Discord | The handler did not reply within 3 seconds. Use `ctx:defer()` then `ctx:edit()`. |
| `ctx:showModal` not available for this interaction type | `showModal` works only from a slash command or a component, not from a modal submit. |
| Validation error while building | The message names the limit that was exceeded (length, count, format). Fix it accordingly. |
| Components V2: `content/embeds` error | A V2 message cannot carry `content` or `embeds`. |

## 12. Security

- Do not share the bot token in scripts you distribute. Keep it in a local file or read it at runtime.
- Restrict who can trigger actions that change the game. For example, check `ctx.user_id` against a list of admin IDs before running a handler.
- Validate all user input before it reaches game functions. For `SendPacket`, strip newlines and `|` so the text cannot add packet fields. For world names, accept letters and digits only.
- Code loaded from GitHub runs inside the game and can read the token. Use your own repository and pin to a tag or commit hash.
- Do not use `insecure = true` outside local testing.

## 13. Build and test

Build (aarch64, mbedTLS) in Termux:

```sh
pkg install -y clang make curl unzip bzip2 binutils lua54
cd ~/libdiscord && chmod +x build.sh && ./build.sh
```

`build.sh` and the `Makefile` download Lua and mbedTLS on the first build. Use `LUA_VER=5.4.7 ./build.sh` if your executor's Lua differs. A correct build exports only `luaopen_discord`.

Local tests without Discord use a mock gateway:

```sh
python3 mock_gateway.py GW_PORT API_PORT normal   # or zombie
lua test_bot.lua GW_PORT API_PORT normal
```

Other tests: `tests/test_builders.lua`, `tests/test_example_unit.lua`, `tests/test_json_decode.lua`, `tests/test_client.lua`, and `test_latency.lua`.

### Test status

On x86_64 in a sandbox (TLS disabled, with ASan and UBSan), the builder tests, example unit tests, `json_decode`, client end-to-end tests, and the bot against the mock gateway pass. These have not been verified on a device or against real Discord: the aarch64 TLS build, interactive components (buttons, selects, modals, autocomplete), downloading the `.so` through `MakeRequest`, and `OnDraw` behavior while the game is minimized.

Full example: `examples/discord_slash.lua`. Ready-made Components V2 panel: `kazloader_v0.8.0.lua`.
