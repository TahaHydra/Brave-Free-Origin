## What and why

<!-- One or two sentences. Link the issue if there is one: "Fixes #123". -->

## Checklist

- [ ] `Brave-Free-Origin.ps1` is still pure ASCII (CI checks this) and targets Windows PowerShell 5.1
- [ ] Sandboxed app tests pass: `powershell -NoProfile -ExecutionPolicy Bypass -File .\Brave-Free-Origin.ps1 -SelfTest .\tools\Test-App.ps1`
- [ ] If I changed English text or the catalog: ran `tools\Export-EnglishLocale.ps1` and `tools\Export-PolicyDocs.ps1` and committed the results
- [ ] If I touched a locale file: `tools\Test-Locales.ps1` passes
- [ ] New or changed settings were checked against a real Brave (say which version below) and have a plain title and description
- [ ] `CHANGELOG.md` has a line for this change

## Checked on

<!-- Brave version (brave://version), Windows version. -->
