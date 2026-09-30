# Contributing to Brave Free Origin

Thanks for helping. This is a small project, so the process is small too.

## Ways to help

| I want to... | Do this |
| --- | --- |
| Report a bug | [Open an issue](https://github.com/TahaHydra/Brave-Free-Origin/issues/new/choose). Attach the newest file from `%LOCALAPPDATA%\Brave-Free-Origin\logs\`, the app version (window title) and your Brave version (`brave://version`). |
| Fix or add a translation | [TRANSLATING.md](TRANSLATING.md). One JSON file, no PowerShell. |
| Report that a policy stopped working on a newer Brave | Open an issue with your Brave version and a screenshot of the row on `brave://policy`. |
| Add or change a setting | Read "Changing the catalog" below. |
| Report a security problem | [SECURITY.md](SECURITY.md). Not in a public issue. |

## Repository layout

```
Brave-Free-Origin.ps1     the whole app: one file, pure ASCII, Windows PowerShell 5.1
Brave-Free-Origin.bat     double-click launcher (portable ZIP)
install/bfo.ps1           the one-line installer served at https://xhydra.fr/bfo
locales/                  UI translations (JSON, UTF-8 without BOM); en-US.json is generated
docs/POLICIES.md          plain-language reference of every setting (generated)
tools/                    maintainer scripts: tests, generators, packaging (not shipped)
.github/workflows/        CI and the release workflow
```

`Brave-Free-Origin.ps1` is organised in regions (search for `#region`): Bootstrap, i18n runtime, English catalog, Catalog data, Core (registry, hosts, tasks), Model (items, presets, plan), Scriptlets, UI, Startup. The window only reads and writes the item list in the model; Preview, Apply and Verify all derive from one plan, so what you see is what gets written.

## Rules of the road

- **The app stays pure ASCII and CRLF.** Windows PowerShell 5.1 decodes a BOM-less script with the system code page, so a stray "curly quote" would turn into garbage on some PCs. Text for users belongs in `locales\*.json`; the English catalog is embedded as ASCII.
- **Target Windows PowerShell 5.1** (what the launcher starts). No `&&`, no ternary, no `??`, no `?.`. Test on 5.1; CI also parses with PowerShell 7.
- **Never use PowerShell's automatic variables as your own names.** `$pid`, `$home` and `$host` are read-only (`Cannot overwrite variable`), and shadowing `$args`, `$input`, `$error` or `$matches` gives confusing results. Also remember that `switch` runs every matching branch unless you `break`.
- **Layout uses Dock, TableLayoutPanel and FlowLayoutPanel only.** Absolute positions break under right-to-left mirroring (Arabic) and on small screens.
- **Every event handler goes through `Invoke-Guarded`** so a failure is shown, logged and never crashes the window.
- **Anything that changes the machine must be reversible** and must show up in Preview. The updater and hosts pages are never touched by presets.
- No new network calls in the app. No `Invoke-Expression` on anything that is not a literal in the file.

## Running the tests

All of these run without administrator rights and without touching a real Brave install (policies go to a throw-away `HKCU` hive, the hosts file is a temp file, tasks and services are in-memory fakes):

```powershell
# the app itself, in its sandbox (about 20 seconds; BFO_TEST_SHOTS=1 also saves a screenshot per page and language)
powershell -NoProfile -ExecutionPolicy Bypass -File .\Brave-Free-Origin.ps1 -Lang en-US -SelfTest .\tools\Test-App.ps1

# the locale files against the embedded English catalog
.\tools\Test-Locales.ps1

# the one-line installer against a fake GitHub on loopback (Windows PowerShell and pwsh)
.\tools\Test-Bootstrap.ps1
```

## Changing the catalog (adding or editing a setting)

1. Confirm the policy exists in the Brave you target: run `tools\Export-BravePolicyNames.ps1 -Check` (compares the catalog with your installed Brave's policy table), open `brave://policy`, tick *Show policies with no value set*, or read the definitions in [brave-core](https://github.com/brave/brave-core/tree/master/components/policy/resources/templates/policy_definitions/BraveSoftware) and Chromium's `policy_definitions`. Check the meaning of every allowed value; Brave's naming is inconsistent (`*Disabled` is switched off by `1`, `*Enabled` by `0`).
2. Add one line to `$script:PolicyTable`: `Page|Name|Type|Value|Kind|Risk|Lock|Presets`. `Kind` is `Off` (turns a feature off), `On` (keeps a protection on) or `Set`; `Lock` is `1` when Brave already behaves this way by default; the last field lists the presets that tick it (`Q` Quick Debloat, `O` Origin, `R` Recommended, `B` Privacy + Boost, `X` Max Performance, `P` Max Privacy).
3. Add `policy.<Name>.title` (an imperative that says what happens) and `policy.<Name>.description` (what actually changes, including side effects) to the English catalog. If you cannot say it in one or two plain sentences, the row is not ready.
4. Regenerate the generated files and run the tests:

   ```powershell
   .\tools\Export-EnglishLocale.ps1   # locales/en-US.json
   .\tools\Export-PolicyDocs.ps1      # docs/POLICIES.md
   .\tools\Export-BravePolicyNames.ps1  # tools/data/brave-policy-names.txt, only when you moved to a newer Brave
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Brave-Free-Origin.ps1 -SelfTest .\tools\Test-App.ps1
   ```

   The tests pin the preset ladder (Quick < Recommended < Boost < Max Performance, Origin is exactly Brave Origin's 16, presets never touch the updater) and check that every row has a title and description.
5. Add a line to `CHANGELOG.md` and, if the checked Brave build changed, update `$script:CatalogBrave` / `$script:CatalogDate`.

## Pull requests

Small, focused PRs are easiest. The checklist in the PR template is short. CI (`.github/workflows/ci.yml`) runs the static checks, the sandboxed app tests, the installer tests and builds the zip; it must be green.

## Releasing (maintainers)

1. Bump `$script:AppVersion`, update `CHANGELOG.md` (the release notes are taken from its `## [x.y]` section), regenerate the generated files, run the tests.
2. Tag and push: `git tag v1.13 && git push origin v1.13`. The **Release** workflow first runs the whole CI workflow, then checks the tag against the app version, builds `Brave-Free-Origin.zip` and `SHA256SUMS.txt` with `tools\Build-Package.ps1`, and publishes the release. The asset name must stay `Brave-Free-Origin.zip`: the one-line installer downloads exactly that file and verifies it against the checksum GitHub records.
3. The installer script is served from `install/bfo.ps1`; see [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for hosting notes.
