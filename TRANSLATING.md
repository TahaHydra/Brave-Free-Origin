# Translating Brave Free Origin

Thanks for helping. Adding a language means adding **one JSON file**. You never need to touch the PowerShell.

---

## The short version

1. Copy `locales/en-US.json` to `locales/<your-locale>.json` (e.g. `de-DE.json`, `pt-BR.json`, `ja-JP.json`).
2. Edit the `meta` block.
3. Translate the values under `strings`. Leave the keys alone.
4. Save as **UTF-8 without a BOM**.
5. Run `tools\Test-Locales.ps1`, then open a PR. CI runs the same check.

Partial translations are fine and ship happily: anything you leave out falls back to English at runtime, key by key. CI asks for at least 95% coverage for a file to be *merged into the release*; a work-in-progress PR can be lower.

## What ships today

| File | Language | Status |
| --- | --- | --- |
| `en-US.json` | English | Reference, generated from the app. Never loaded at runtime. |
| `fr-FR.json` | Français | Machine-assisted, unreviewed |
| `es-ES.json` | Español | Machine-assisted, unreviewed |
| `hi-IN.json` | हिन्दी | Machine-assisted, unreviewed |
| `ar.json` | العربية (right-to-left) | Machine-assisted, unreviewed |
| `zh-CN.json` | 简体中文 | Requested in [#4](https://github.com/TahaHydra/Brave-Free-Origin/issues/4); strings new in 1.13 machine-assisted |
| `zh-TW.json` | 繁體中文 | Contributed by @tsai97216; strings new in 1.13 machine-assisted |

**The most useful contribution is a native speaker reading a file top to bottom** and fixing whatever sounds wrong. Once a second speaker has read it, set `"reviewed": true`, add yourself to `translators`, and the app stops showing the *community translation, unreviewed* note.

---

## The `meta` block

```json
{
  "meta": {
    "locale": "fr-FR",
    "name": "Français",
    "englishName": "French",
    "appVersion": "1.13",
    "translators": ["your-github-handle"],
    "reviewed": false,
    "direction": "ltr"
  },
  "strings": {
    "action.apply": "Appliquer à Brave"
  }
}
```

| Field | Notes |
| --- | --- |
| `locale` | Must match the filename exactly. This is what `-Lang` accepts. |
| `name` | The language's own name. This is what the picker shows. |
| `englishName` | For maintainers who can't read `name`. The picker sorts by it. |
| `translators` | Credit yourself. Only list people who actually wrote or reviewed the text; asking for a language in an issue is a request, not authorship, and gets recorded in `note` instead. Leave it `[]` if nobody has claimed the wording. |
| `reviewed` | Leave `false` until a second speaker of the language has read it. While `false` the app shows a small "community translation, unreviewed" note under the language picker. |
| `direction` | Optional. `"rtl"` mirrors the whole window for right-to-left languages (Arabic ships with it). Omit it or use `"ltr"` otherwise. Arabic, Hebrew, Persian and Urdu are recognised by their language code even without it. |
| `note` | Optional free text, for provenance: who requested the language, what still needs review. |

Delete `generated` if you copied the block from `en-US.json`; that flag belongs to the generated reference file.

---

## Rules that CI enforces

These aren't style preferences; a PR that breaks one will fail.

The **runtime** enforces the same rules independently, key by key, because locale files are also just files a user can drop into `locales\` by hand. A key that breaks a rule is dropped and its English text is used instead; a file that is malformed, not UTF-8, or missing its `strings` block is ignored entirely and the app stays in English rather than crashing. Nothing in a locale file is ever executed: no `Invoke-Expression`, no `Import-LocalizedData`, just `ConvertFrom-Json` over inert data. So a broken translation is a cosmetic problem, never a broken app. CI exists so you find out before your users do.

**Keys are fixed.** You may only translate keys that already exist in English. A key CI doesn't recognise is a typo, and a typo that silently did nothing would be worse than a build failure. To *add* a key, the English catalog in `Brave-Free-Origin.ps1` has to change first, which is a maintainer change.

**Placeholders must survive.** `{0}`, `{1}` and so on get replaced with live values. Keep every one, keep the numbers the same. You can reorder them if your language needs a different word order:

```
"bar.pending": "{0} pending:  {1} to apply,  {2} to change,  {3} to remove"
"bar.pending": "{0} en attente :  {1} à appliquer,  {2} à modifier,  {3} à retirer"      <- fine
"bar.pending": "{0} en attente :  {1} à appliquer"                                       <- fails, {2} and {3} dropped
```

**Doubled braces stay doubled.** `{{searchTerms}}` renders as literal `{searchTerms}`, the placeholder Brave itself fills in. If you write it with single braces the app will try to substitute it and the text will break.

**`\r\n` and `\n` are real line breaks** inside dialog text. Keep the same number of them so dialogs keep their shape.

**No control characters** other than tab, CR and LF. **Values cap at 2000 characters.** Duplicate keys, non-string values and unknown `meta.direction` values are rejected.

---

## What is *not* translatable, on purpose

None of these appear in the string catalog, so you won't run into them. If you are wondering why they stayed English:

- **Policy names** (`BraveRewardsDisabled`, `DefaultBraveAdblockSetting` and the rest). Users cross-check them against `brave://policy`. The *title and description* next to each are translatable; the identifier is not.
- **Scheduled task and Windows service names**: real system identifiers.
- **Domains, registry paths, URLs, `{searchTerms}`**: they live in the data model, not the catalog. A locale file structurally cannot change them. That is the whole point of keeping translations as inert data.
- **Search engine brand names**: "DuckDuckGo" is "DuckDuckGo". The one entry with real words is `engine.custom`. The provider name written to the registry is a separate, untranslated field, so Brave always shows a stable name.
- **Scriptlet raw rules and the `! BFO disabled: ` marker.** The marker is matched literally when re-enabling a rule and when reapplying an exported preference file; translating it would orphan every edit a user had already made. Rule text itself is Brave's data, not ours.
- **The log, the Preview report and the Verify report.** Deliberate: a user running the app in Japanese should still be able to paste a report into a GitHub issue that the maintainer can read. If your users push back on this, open an issue and we'll reconsider.

Two things that *are* translatable and easy to miss:

- **The Scriptlets table**: its column headers (`scriptlet.col.*`) and the per-row `Enabled` / `Disabled` cell (`scriptlet.state.*`).
- **File-dialog filters**: only the human half (`dialog.filter.textReport` = "Text report"). The app adds the `(*.txt)|*.txt` part itself.

---

## How the words work in this app

The whole point of the 1.13 interface is that nobody should have to guess what a checkbox does. Your translation carries that.

- A **row** is one Brave setting. Its **title** says what happens ("Turn off Brave Rewards"), its **description** says what actually changes, in plain words.
- **Ticked** = this tool enforces the row. For most rows that switches a feature *off*. **Unticked** = Brave decides again, and Apply removes the policy this tool wrote earlier. Use your language's everyday words for *tick / untick a checkbox* and use the same ones everywhere (`tip.*`, `help.tick.*`, `policyTab.*`, `filter.selectedOnly`).
- **Status** words (Active, Will apply, Will change, Will remove, Not set...) and **Risk** words (Safe, Low, Medium, High) sit in narrow columns: one or two short words.
- Use the wording your language's **Windows** uses for Windows features (Task Scheduler, Services, the hosts file, the administrator prompt) and the wording **Brave** uses for its own menus.
- Keep the register friendly and direct. Translate meaning, not words. Do not soften a risk or add a claim the English does not make.
- Build a small glossary first (policy, preset, Apply, Preview, Restore stock, updater, telemetry, Shields...) and use each term the same way everywhere.

## Strings worth extra care

Get these wrong and someone loses their DRM playback, their sign-in or their browser updates. Please have a second pair of eyes on them before flipping `reviewed` to `true`:

- `policy.ComponentUpdatesEnabled.description`, `hosts.components.description`
- `policy.DefaultBraveRemember1PStorageSetting.description`, `policy.NTPCustomBackgroundEnabled.description`
- `preset.MaxPrivacy.description` / `.risk`, `preset.MaxPerformance.description` / `.risk`
- `updater.warning`, `msg.updater.confirm`
- `msg.restore.confirm`, `msg.restore.confirmForeign`
- `msg.scriptlet.confirmDisable`, `msg.scriptlet.confirmRestoreAll`, `scriptlet.risk`

A translation that makes a destructive option sound routine is worse than no translation at all.

---

## Layout notes

The window is built from docked panels and tables, so text wraps and columns share the available width instead of sitting at fixed positions. Length still matters in a few places:

- **Buttons, sidebar entries and grid column headers** are the tightest. Stay within about 130% of the English length; sidebar page titles at most about 26 Latin characters (or 13 CJK characters).
- **Descriptions** wrap and rows grow to fit, but very long text makes the list scroll a lot. Keep them to one or two sentences like the English.
- **Right-to-left languages** (`"direction": "rtl"`): the whole window is mirrored and every control is right-aligned. Keep product names, policy names, URLs and numbers in Latin script; avoid the `>` character (it is mirrored in right-to-left text) and use a word such as "then" instead of an arrow.
- **Fonts** are chosen per script: Segoe UI (Latin, Cyrillic, Greek, Arabic), Microsoft YaHei UI (`zh-CN`), Microsoft JhengHei UI (`zh-TW`), Nirmala UI (Hindi and other Indic scripts). If your script needs a different family, say so in the PR and we will extend the font plan.

---

## Testing your file locally

```powershell
# Validate before opening the PR (same checks CI runs). No arguments needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Locales.ps1

# See your language in the real window (asks for administrator permission; nothing is written until you press Apply)
.\Brave-Free-Origin.ps1 -Lang fr-FR

# Run the whole sandboxed test suite, which also switches through every language and checks
# for missing text, the right direction and the right font (no admin, no real Brave touched)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Brave-Free-Origin.ps1 -SelfTest .\tools\Test-App.ps1
```

`pwsh -File tools\Test-Locales.ps1` works too. CI runs it both ways, because the app itself is launched by `powershell.exe` (Windows PowerShell 5.1) and that is the host that has to work.

Maintainers only: after changing any `Add-Strings` entry in the app, regenerate the translator reference and the policy reference, and commit them. The generators never touch your machine's Brave, and their output is identical under both hosts, so CI can diff it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Export-EnglishLocale.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Export-PolicyDocs.ps1
```

Things worth clicking through:

- Every page in the sidebar, including **Search engine and startup** and **Hosts blocklist**.
- Each preset: is the description under the strip clipped or wrapped badly?
- The search box and the **Ticked only** filter.
- **Preview changes** and **Verify**: these stay English, that is expected.
- **Tools > How this works...** and the result dialog after Apply.
- Switch back to English from the picker. Everything should re-text live, including dropdowns, tooltips and the preset strip.
- Export a config in your language, switch to English, import it. The checkboxes must come back identical. If they don't, that's a bug in the app, not your translation: please report it.

---

## Adding a language to the picker

Nothing to do. The picker enumerates `locales\*.json` at startup. Drop the file in, restart, it's there.

Locale resolution order at startup: `-Lang`, then the saved preference in `%LOCALAPPDATA%\Brave-Free-Origin\settings.json`, then the Windows display language, then a same-language file, then English. So a PC in a language we do not ship simply gets English.

The same-language step is script-aware, which matters for Chinese. `zh-CN`, `zh-SG`, `zh-MY`, `zh-Hans-*` and bare `zh` resolve to `zh-CN.json`; `zh-TW`, `zh-HK`, `zh-MO` and `zh-Hant-*` resolve to `zh-TW.json` (and to **English** if it is not installed, because Simplified text is not an acceptable substitute for a Traditional reader). Languages without a script split match on the language subtag alone, so `fr-FR.json` serves an `fr-CA` machine and `es-ES.json` serves `es-MX`.

---

## If something in English reads badly

Say so in the issue. Awkward source English usually means the string is doing too much, and fixing it helps every translation. Don't paper over it.
