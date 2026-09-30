# Changelog

All notable changes to Brave Free Origin. Newest first. Every release is checked against a specific Brave build; the app tells you when yours is newer or older, and anything the tool writes can be undone with **Restore stock**.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow the app's own numbering.

## [2.0.1] - 2026-09-30

Fixes for 2.0: switching language while the app is open no longer closes the window, and the question before Apply is easier to read and more careful about what it treats as yours.

### Fixed
- **Switching language live** (most visibly to or from Arabic, which mirrors the whole window) could close the main window. The window now runs on the normal application loop, which survives that change.
- **Keeping a setting really keeps it.** Choosing *Keep all existing* (or unticking a row) in the question before Apply now also unticks that setting in the main window, so the window shows what will happen and you are not asked again next time. A kept search engine, New Tab page or startup choice stays whole.
- A policy that already holds the value BFO would write, but that BFO never recorded writing, now shows **Set elsewhere** instead of **Active**.

### Changed
- **Simpler wording.** The question before replacing settings is now *Review existing settings* (columns *Current* and *Selected*; buttons *Apply selected changes*, *Keep all existing*, *Cancel*). The result window shows one line ("3 change(s) applied.") and tells you to reopen Brave. *Open brave://policy* is now *View in Brave* and *Verify* is *Check changes*. Policy names and values are hidden by default; **Show policy names** brings them back.
- **Ownership is conservative.** BFO treats a value as its own only when it recorded writing that exact value (plus the clean-up names older versions used). After upgrading from an older version BFO may therefore ask once about policies that version set; nothing is replaced or removed without your answer. Restore stock removes what BFO recorded and asks before touching anything else. README and SECURITY.md say so.
- All seven languages follow the new wording.

### Project
- The README starts with the one-line install command.
- Release pages are short: install lines and a summary, with the details folded away. Older releases are hidden from the Releases page (their source stays on the Tags page).

## [2.0] - 2026-09-30

A ground-up rework of the interface and of the policy catalog: version 2.0 of Brave Free Origin. The goal: **you should always know what a checkbox does before you tick it, and what the tool wrote after you press Apply.** Checked against **Brave 154.1.96.59 (Chromium 154) on 2026-09-29**; everything the tool writes is still reversible. The problems found in v1.12 are tracked in [#19](https://github.com/TahaHydra/Brave-Free-Origin/issues/19) (issues #7 to #18).

### Easier to understand
- **Every setting is a plain-language row.** A title that says what happens ("Turn off Brave Rewards"), one sentence about what actually changes, a **Status** column (Active / Will apply / Will change / Will remove / Not set) and a **Risk** column (Safe / Low / Medium / High). The technical policy name is one click away (**Show policy names**) and in the tooltip.
- **Tick / untick is spelled out everywhere.** Tooltips say "When ticked: this feature is switched off" and "When unticked: Brave decides again". Rows that only lock a protection Brave already uses by default say so.
- **See before you write.** The bottom bar counts what is pending ("6 pending: 4 to apply, 1 to change, 1 to remove"). **Preview changes** lists every registry value, hosts entry and updater switch before anything is written; the result dialog explains what to do next (restart Brave, open `brave://policy`).
- **New layout.** A sidebar with live "ticked / total" counts replaces the row of tabs, a preset strip with a one-line description, risk and count per preset sits at the top, search covers every page at once, and a **Ticked only** filter shows exactly what a preset enforces.
- **A clearer first screen.** Before you pick anything the header says what to do ("Pick a preset above or tick rows below; nothing changes until you press Apply"), the search box shows a hint, the search and "Ticked only" controls disappear on the two form-style pages they do not cover, and the technical column is named for what a page lists (Policy, Domains or Name). The window and taskbar now carry the new Brave Free Origin mark.
- **In-app help** ("How this works") explains ticking, statuses, undoing everything, the "Managed by your organization" note and Brave version differences.
- **Brave version banner.** If your Brave is newer or much older than the version this list was checked against, the app says so and reminds you that unknown policies are ignored and everything is reversible.
- **Faster and smaller.** The window opens in about 0.6 s instead of about 5.6 s on the author's PC, fits small screens, and there is no tab strip left to overflow.

### Seven languages, right-to-left included
- **English, Français, Español, हिन्दी, العربية, 简体中文, 繁體中文.** The app starts in your Windows display language when it has it and in English otherwise; switch any time from the header, no restart. Arabic mirrors the whole window right-to-left. Fonts are chosen per script (Segoe UI, Microsoft YaHei UI, Microsoft JhengHei UI, Nirmala UI).
- New strings in French, Spanish, Hindi and Arabic are machine-assisted and unreviewed; the app shows a small "community translation, unreviewed" note until a native speaker signs a file off. See [TRANSLATING.md](TRANSLATING.md).

### The policy list was audited against a real Brave 154
- **101 policies, every one compiled into Brave 154.1.96.59.** Each row was checked against the browser's own policy table and against the brave-core and Chromium sources.
- **Fixed silent failures.** `MediaRouterEnabled` never existed (the real policy is `EnableMediaRouter`); `BatterySaverModeAvailability` was written with a deprecated value and a reversed description; `GenAiDefaultSettings` is cloud-only, so registry values are ignored. The individual AI policies are used instead.
- **Removed dead policies** that Brave 154 ignores: `WebTorrentDisabled`, `ChromeCleanupEnabled`, `ChromeCleanupReportingEnabled`, `TabOrganizerSettings`, `CloudPrintSubmitEnabled`, `WelcomePageOnOSUpgradeEnabled`, `ReadingListEnabled`, `IPFSEnabled`; replaced deprecated ones (`PromotionalTabsEnabled` -> `PromotionsEnabled`; `SigninAllowed` and the three Lens policies dropped in favour of their current equivalents).
- **New pages and rows:** site permissions (WebUSB, Bluetooth, Serial, HID, sensors ...), more Shields locks, the individual generative-AI policies, passwords and autofill, safety prompts, and Brave-only features (Tor, Wayback Machine, Playlist, Speedreader, Email Aliases, Privacy Settings Tuning).
- **Descriptions rewritten** to say what really happens, including side effects that were missing (for example, removing a custom New Tab background is permanent).

### Presets are a ladder you can reason about
- **Quick Debloat** (6) < **Recommended** (42) < **Privacy + Boost** (54) < **Max Performance** (61); **Max Privacy** (73) builds on Recommended; **Origin Mode** is exactly the 16 policies Brave Origin itself ships. The lighter presets never change how passwords, autofill or sync behave; only Max Privacy does, and only Max Performance asks for a fresh start instead of restoring your session.
- Presets no longer touch the updater switches or the search / new tab / startup overrides.

### Safer changes to your system
- **Existing settings are never replaced in silence.** If Apply would change or remove a policy value this tool did not write (set by hand, by another tool or by your organization), it stops and shows an *Existing Brave policies detected* window: every entry with its current value and the value BFO wants (or *remove it*). **Apply BFO changes anyway** replaces the ticked entries (all start ticked), **Keep existing settings** keeps them all and still applies everything else, **Cancel** writes nothing, and unticking one entry keeps just that one. A search engine, a New Tab page or a startup choice is one entry that is kept or replaced whole, never half and half. *Do this every time without asking*, or **Tools > Settings already set elsewhere** (ask / always replace / always keep), makes the answer permanent. Rows say **Will replace** beforehand, Preview flags the values, the result window counts what was replaced and what was kept, and the log names each one.
- **The tool remembers what it wrote.** The registry cannot say who wrote a value, so Apply records the values it writes (per Windows user, in `settings.json`). A custom search address or a list of startup pages typed into the app can later be changed or removed without a question; values from earlier versions are recognised by the lists the app knows. Restore stock forgets the record.
- **Hosts file:** the blocklist groups were rebuilt from real Brave traffic (wrong and harmful entries such as the component-updater servers are never pre-ticked). Editing preserves your own entries byte for byte, whatever the file's encoding or line endings, handles read-only and UTF-16 files, and backs up first.
- **Config import:** importing a config can only tick updater rows ("disable this"); it never unticks one, so it cannot re-enable an updater you turned off. Exports list only ticked updater rows.
- **Hosts markers:** the block is edited only when its START / END markers pair up; a damaged block is reported and the file is left untouched. The read-only flag is put back even when a write fails.
- **Scriptlets:** filter-list files are split on LF, CRLF and CR alike and written back with their own line endings.
- **Updater switches:** scheduled tasks and services are now found by pattern (Brave names them with a GUID and your account's SID, so exact names never matched), only rows you changed produce operations, and turning updates off asks first. Restore stock turns everything back on.
- **One policy key.** Brave reads a single policy key for Stable, Beta, Nightly and Dev, so the channel selector is gone (the old per-channel keys were inert). **Restore stock** still cleans them up. Restore stock removes only values this tool could have written (same name, same kind of data, a value from its own list, or one it remembers writing); a known policy holding some other value is shown as **Set elsewhere**, reported by Verify and kept unless you choose to remove everything. Apply asks before replacing such a value (see above).
- **Opening `brave://policy` works.** Brave is now started un-elevated through Explorer (Chromium 138+ refuses or mis-handles an elevated launch); if that ever fails the address is copied to the clipboard.

### Errors are explained, not hidden
- Every button is wrapped: a failure shows a message, is written to `%LOCALAPPDATA%\Brave-Free-Origin\logs` and never closes the window. A start-up failure shows a dialog with the log path instead of a vanishing hidden console; declining the UAC prompt is a friendly note, not a red error.
- Backup, apply and verify messages now say exactly what happened, including partial failures.

### Two ways to start it
- **One line:** `irm https://xhydra.fr/bfo | iex` downloads the release from GitHub, checks its SHA-256 against the checksum GitHub publishes, unpacks it to a temporary folder, starts it with a one-process execution-policy bypass and a UAC prompt, and cleans up when you close it. Nothing is installed. Options: `BFO_VERSION`, `BFO_LANG`, `BFO_NO_LAUNCH=1` (download and verify only, so you can read the files first).
- **Portable:** download `Brave-Free-Origin.zip`, extract, double-click `Brave-Free-Origin.bat`. The launcher now explains exit codes (declined UAC, blocked scripts) and where the log is.

### For contributors
- `tools\Test-App.ps1`: about 65 sandboxed tests (policies go to a throw-away HKCU hive, the hosts file is a temp file, tasks and services are fakes, no UAC): catalog integrity, preset invariants, apply / verify / restore, hosts encodings, updater matching, window layout, every language switch.
- `tools\Test-Bootstrap.ps1`: 16 tests of the one-line installer against a fake GitHub on loopback.
- `tools\Export-BravePolicyNames.ps1` reads the policy table out of an installed Brave's `chrome.dll`: `-Check` compares the catalog with that Brave, and the snapshot in `tools\data` lets the tests fail when the catalog offers a policy Brave does not know.
- The release workflow now runs the whole CI workflow before it publishes, and can be started by hand as a dry run.
- `docs\POLICIES.md` is generated from the catalog by `tools\Export-PolicyDocs.ps1` (CI fails if it drifts). `tools\Build-Package.ps1` builds the zip and its SHA-256; a release workflow publishes it when you push a `v*` tag.
- Configs exported by v1.5 to v1.12 still import; exports are now schema 3.
- `README.md` is shorter; the version-by-version notes live here.

## [1.12]
Two user-facing features, and a large internal refactor that had to land first.

- **Translatable interface.** A `Language` dropdown in the header switches the
  whole UI live. Simplified Chinese (`zh-CN`) ships in the box — support added
  in response to [#4](https://github.com/TahaHydra/Brave-Free-Origin/issues/4),
  opened by [@A81N9](https://github.com/A81N9). The Chinese wording has **not**
  been reviewed by a native speaker yet, so `locales/zh-CN.json` carries
  `"reviewed": false` and the app shows a small *community translation,
  unreviewed* note under the picker. Review PRs are very welcome.
  Adding a language is one JSON file — see [TRANSLATING.md](TRANSLATING.md).
- **Global configuration filter.** A search box above the tabs filters
  policies, scheduled tasks, Windows services and hosts groups at the same
  time, matching on name, description and category — in whichever language the
  UI is currently in, and on the untranslated policy identifier either way.
  Hidden rows collapse instead of leaving gaps, each tab caption shows its
  match count, and the view jumps to the first tab with a hit. Filtering is
  purely presentational: it never changes a selection. A **Selected only**
  checkbox shows just what is currently ticked — pair it with a preset to
  review exactly what is about to be enforced. `Search & Startup` and the
  Scriptlets tab are not part of this index; Scriptlets keeps its own
  dedicated scanner, which handles thousands of rows and is already tuned.
- **Stable internal ids, separated from labels.** Presets, hosts groups,
  search engines, new-tab destinations, startup modes, policy categories and
  the channel selector previously used their English display text as the
  lookup key. Translating the UI would have silently broken preset behaviour
  and config import. Everything now keys off a language-independent id and the
  visible label is looked up separately.
- **Config schema v2.** Exports now carry `schemaVersion` (the file format)
  and `appVersion` (the app) as separate fields, so gaining a button no longer
  looks like a format change. Hosts groups, search engines, new-tab
  destinations and startup modes are stored by id. **Configs exported by
  v1.5-v1.11 still import correctly** — the old English names are mapped on
  the way in. A config exported in Chinese imports identically in English and
  vice versa.
- **`-Lang` and settings survive elevation.** The relaunch after the UAC
  prompt used to rebuild a fixed command line and drop every parameter. It now
  forwards `-Lang` and the resolved settings path, so an elevated
  administrator account still reads the original user's preference file.
- **Switching language changes nothing but text.** Relabelling a dropdown
  means clearing and refilling its items, and WinForms reports that as a user
  selection change — which would have quietly demoted `Recommended` to
  `Custom` and could have moved the hardware-acceleration value. Every bulk
  update (language switch, preset, config import, *Load current state*, full
  restore) now runs with the change handlers muted, restores the exact
  selected id, and re-asserts the active mode afterwards.
- **CJK layout handling.** Microsoft YaHei UI is used for `zh-*` when
  installed, with taller rows and a larger description font, and every
  localized control re-resolves its font on a switch instead of staying pinned
  to Segoe UI, which has no CJK coverage. Row geometry is recalculated from
  the *active* locale in both directions, so going back to English shrinks the
  rows again rather than leaving tall labels inside short rows. The preset
  button row measures its captions and re-flows instead of using fixed X
  positions, so a longer translated label cannot overlap its neighbour.
- **Traditional Chinese is never served Simplified.** Locale matching is
  script-aware: `zh-CN` / `zh-SG` / `zh-Hans-*` resolve to `zh-CN`, while
  `zh-TW` / `zh-HK` / `zh-MO` / `zh-Hant-*` fall back to English until a
  Traditional Chinese file exists.
- **The script stays pure ASCII.** Windows PowerShell 5.1 decodes a BOM-less
  `.ps1` with the system ANSI code page, so literal Chinese in the app would
  mojibake on machines with a different code page. Translations live in
  `locales\*.json` and are read with an explicit UTF-8 decoder.
- **Community locale files are treated as hostile data.** A file dropped into
  `locales\` by hand is parsed as inert JSON — never executed, never through
  `Invoke-Expression` or `Import-LocalizedData`. It may only replace keys
  English already defines, so it cannot introduce a registry path, policy
  name, domain, URL or numeric value. Unknown keys, non-strings, over-long
  values, control characters and mismatched `{0}` placeholders are rejected
  key by key and fall back to English; a malformed or invalid file leaves the
  app in English instead of crashing it.
- **Locale tooling and CI.** `tools\Test-Locales.ps1` validates encoding,
  JSON, duplicate keys, unknown keys, placeholder parity, escaped braces,
  control characters, value length and metadata.
  `tools\Export-EnglishLocale.ps1` regenerates `locales\en-US.json` from the
  embedded catalog by parsing the app's syntax tree — it never executes the
  app — and writes byte-identical output under Windows PowerShell 5.1 and
  PowerShell 7. CI runs both tools under **Windows PowerShell 5.1**, which is
  what the launcher actually uses, as well as under PowerShell 7, and enforces
  the ASCII rule, the locale encoding rules and the portable-zip contents.

Behaviour is otherwise unchanged: the same policies, the same registry writes,
the same hosts handling. Every preset's policy / task / service / hosts payload
was diffed against v1.11 as part of this release and is identical once the
hosts groups are mapped from their old English names to the new ids, as are the
search-provider names, URLs, suggest URLs, keywords, homepages, new-tab
destination values and `RestoreOnStartup` codes that reach the registry. The
Scriptlets tab remains manual-only: it is never touched by a preset, by
`Apply to Brave`, or by anything that runs at startup. If you find any
difference in what gets applied between v1.11 and v1.12, that is a bug —
please open an issue.

One genuine fix landed alongside: the 32-bit `Program Files (x86)` probe for
`brave.exe` was written `"$env:ProgramFiles(x86)\..."`, which PowerShell
expands as `$env:ProgramFiles` followed by a literal `(x86)`, so it could
never match. It is now `"${env:ProgramFiles(x86)}\..."`.

## [1.11]
This fixes the scriptlet scan hang from v1.10.

- **Chunked in-app scanner.** Replaces the background-job scan with a timer-based chunk scanner, avoiding the slow PowerShell job serialization step that could sit on `Loading scriptlet scan results...` for minutes.
- **Real progress bar.** The Scriptlets tab now shows a blue progress bar and live status based on files/bytes processed, current file, elapsed seconds, and rules found.
- **Responsive during scan.** The scan yields back to the GUI every small chunk, so Windows should not mark the app as Not Responding while large Brave lists are being read.
- **Chunked table rendering.** Large scriptlet result sets render in batches instead of locking the whole window while thousands of rows are painted.
- **Safer bulk checking.** `Check filtered` now checks every scanned rule matching the current search/filter, including rows that are not currently painted in the table yet.
- **Clearer filtered workflow.** If `Show disabled by this app only` is enabled, `Check filtered` only checks the disabled subset currently being shown. Untick it and clear the search box before bulk-disabling every scriptlet rule.

## [1.10]
This is the scriptlet-manager usability fix.

- **Background scriptlet scan.** Loading Brave's internal scriptlet lists now runs in a background PowerShell job instead of freezing the whole GUI.
- **Faster table refresh.** Search/filter updates use debouncing and bulk row loading, so toggling filters no longer feels like the app died.
- **Checkbox selection.** Scriptlet rows now have checkboxes. Checked rows are used first; normal highlighted selection still works as a fallback.
- **Check filtered / clear checks.** Search for something like `youtube`, click `Check filtered`, then disable or enable the filtered set in one action.
- **Clearer wording.** The UI says `disabled by this app` / `Disabled by Brave Free Origin` instead of assuming everyone knows what `BFO` means. The internal file marker remains `! BFO disabled:` for compatibility with existing backups and disabled rules.
- **Adaptive columns.** The scriptlet table now resizes its columns with the window instead of staying stuck at the original widths.

## [1.9]
This is the advanced scriptlet transparency release. It adds a separate manager for Brave's built-in adblock scriptlets without mixing that risky workflow into the normal presets.

- **Default Scriptlets (Advanced) tab.** Scans Brave `User Data` component folders for filter-list `list.txt` files and lists internal `##+js(...)` scriptlet rules.
- **Viewer columns for auditability.** Shows enabled state, domain, scriptlet name, arguments, source/version, line number, and raw rule.
- **Portable path handling.** Auto-detects Brave Stable/Beta/Nightly/Dev User Data locations from `%LOCALAPPDATA%`, with manual `Browse...` support when Brave lives somewhere unusual.
- **Manual-only advanced editing.** Scriptlet edits are not part of Quick Debloat, Recommended, Origin Mode, Max Performance, Max Privacy, presets, config apply, or the main `Apply to Brave` button. You must open the advanced tab, scan, tick `Advanced edit mode`, select rules, and confirm the action.
- **Per-scriptlet disable/enable.** Disabling comments rules with `! BFO disabled:`. Enabling restores the original rule text.
- **Duplicate handling.** Brave lists can contain the same raw scriptlet rule more than once; the manager can affect duplicate raw rules in the same file so one selection does not leave a twin active by accident.
- **Backup and restore.** Creates `list.txt.bfo-backup` before edits, with buttons to back up all loaded lists, restore the selected file, or restore all scriptlet backups under the selected User Data folder.
- **Export and reapply preferences.** Exports currently disabled raw rules to JSON and can reapply those disabled preferences after Brave updates replace component versions.
- **CSV export.** Saves the visible filtered scriptlet table for inspection, bug reports, or GitHub issue evidence.

## [1.8]
This is the trust-and-restore release. No random checkbox pile-on; the point is making the tool safer to use and easier to audit.

- **Preview changes button.** Generates a dry-run report before writing anything. It shows per-channel policy adds, changes, clears, already-correct values, search/new-tab/startup override changes, scheduled task actions, service actions, and a reminder that hosts are managed separately.
- **Preview hosts button.** The Hosts tab now shows what domains will be added, kept, or removed from the Brave-Free-Origin sentinel block before editing `hosts`.
- **Full restore / stock button.** Replaces the old narrow "Remove ALL policies" behavior. It now removes Brave policy keys, clears the Brave-Free-Origin hosts block, re-enables known Brave update scheduled tasks, and resets known disabled Brave services to Manual.
- **Copy/save reports.** Preview and Verify reports open in a scrollable dialog with Copy and Save report buttons. This makes support/debugging cleaner.
- **Config export version bumped to `1.8`.** Exported JSON now reflects the current app generation.

## [1.7]
Two fixes / additions, both about the ad blocker.

- **Preset bug fix: Origin Mode and Privacy + Boost now enforce ad blocking.** Earlier versions used a hand-curated list that omitted the Shields policies, so picking those modes left ad blocking at Brave's default instead of `Block`. Ad blocking is a **performance win** (fewer requests, less DOM, less JS) on top of being Brave's whole identity, so it belongs in the boost preset. Origin Mode and everything that derives from it now also force `DefaultBraveAdblockSetting=Block`, fingerprint protection to Standard, strict referrers, tracking-param stripping, De-AMP, and debouncing.
- **Extensions section in the Search & Startup tab.** Two convenience buttons that just open install pages in Brave — no force-install, no "Managed by your organization" banner. uBlock Origin Lite (MV3-safe), Brave Shields settings, Bitwarden. Includes a one-line warning about double-blocking if you stack uBO on top of Shields.

## [1.6]
Two additions, both opt-in.

- **Search & Startup tab.** Three independent sections, each gated by its own checkbox so nothing fires unless you explicitly tick it.
  - **Default search engine** for the omnibox: Brave Search, DuckDuckGo, Startpage, Qwant, Ecosia, Mojeek, Kagi, Google, Bing, Yandex, or a custom URL (must contain `{searchTerms}`). Writes the `DefaultSearchProvider*` policies. Untick + Apply removes the override and lets Brave's user-chosen engine come back.
  - **New tab page**: blank / search engine homepage / custom URL. Writes `NewTabPageLocation`. Replaces and overrides anything the Performance tab set.
  - **Startup behavior**: open new tab / restore last session / open blank / open a specific page or comma-separated set. Writes `RestoreOnStartup` and (when applicable) the `RestoreOnStartupURLs` list policy.
  - All three run **last** in the apply order, so they cleanly win over any matching policy ticks in the Performance / Startup tab. They also clear their own keys before writing, so unticking + Apply truly removes the override (no orphan registry entries).
  - Round-trips through Export/Import config and is included in the Verify report.

- **Hosts blocks now wire into presets, with a strict no-orphan rule.** Picking a mode now also pre-ticks the hosts groups whose underlying feature is *also* being disabled by that mode's policies. Specifically:
  - Quick Debloat → P3A, Variations, Stats ping, Web Discovery, Rewards (matches its policy set; News stays unblocked because Quick leaves News policy on).
  - Recommended / Origin / Privacy + Boost → above + News CDN.
  - Max Performance / Max Privacy → above + Component Updates (matches `ComponentUpdatesEnabled = 0`).
  - Stock / None → all unticked.
  - Hosts apply still has its own button in the Hosts tab — presets only suggest, they never write hosts entries silently.

## [1.5]
Four additions, all opt-in and reversible. Nothing changes in existing modes — the new features sit alongside what you already know.

- **Multi-channel target selector** (removed in 2.0: Brave reads one policy key for every channel). A dropdown in the header now lets you point the apply at Brave Stable, Beta, Nightly, Dev, or all installed channels at once. Other channels share the same policy schema but live under separate registry hives.
- **Hosts file blocklist tab.** Optional DNS-level kill switch for Brave telemetry domains. Even if a Brave update bypasses a policy, the network call still fails. Sentinel-tagged in the hosts file (`# === Brave-Free-Origin START ===` / `=== END ===`) so removal is surgical and never touches your other entries. Auto-backs up `hosts` before any write. Has its own Apply / Remove buttons inside the tab — does **not** fire from the main "Apply to Brave" button, so you can never edit hosts by accident.
- **Export / Import config.** Save your tuned checkbox state to a JSON file and reuse it on another machine, or share a community preset. Round-trips policies, tasks, services, and hosts groups.
- **Verify button.** Reads the registry of every target channel and reports back which selected policies are present, missing, or have a wrong value. Also lists currently-blocked hosts entries. Useful when [Brave bug 45106](https://github.com/brave/brave-browser/issues/45106) leaves a feature visible despite the policy being set — `Verify` proves the registry is correct so you know whose problem it is.
