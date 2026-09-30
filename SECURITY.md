# Security policy

Brave Free Origin runs with administrator rights and writes to `HKEY_LOCAL_MACHINE`, so it is held to a higher standard than a typical hobby tool. This page says what it touches, what you have to trust, and how to report a problem.

## Supported versions

Only the **latest release** receives fixes. The app tells you when your Brave is newer or older than the version the policy list was checked against; that is a compatibility note, not a vulnerability.

## What the tool can touch

| Area | What | When |
| --- | --- | --- |
| Registry | Values under `HKLM\SOFTWARE\Policies\BraveSoftware\Brave` (and, only on **Restore stock**, the old per-channel keys earlier versions wrote) | When you press Apply / Restore |
| Hosts file | One marked block (`# === Brave-Free-Origin START` ... `END ===`); the rest of the file is preserved byte for byte; backup first | Only from the Hosts page buttons, and Restore stock |
| Updater | Brave's own scheduled tasks and services (`BraveSoftwareUpdateTask*`, `brave`, `bravem`) | Only from the Updater page, and Restore stock |
| Files | Backups in `Documents\Brave-Free-Origin-Backups`, settings and logs in `%LOCALAPPDATA%\Brave-Free-Origin`, and, only from the expert Scriptlets page, `list.txt` files inside Brave's own component folders (with `.bfo-backup` copies) | As described |

BFO does not infer ownership merely because an existing value looks like something it could write. From 2.x onward, a policy is treated as BFO-owned only when the per-user ledger records that exact value (plus a small set of legacy cleanup-only names). Existing unrecorded values are treated as set elsewhere. They stay untouched unless the user explicitly changes that row or override, and Apply asks before replacing or removing them. Policies that can delete site data or saved browser customization also trigger a separate warning before they are added or changed. It never modifies Brave's program files, never patches binaries, installs no service, adds no scheduled task or startup entry of its own, and the app itself makes no network requests. Translations are inert JSON: they can replace UI text and nothing else (no registry path, policy name, domain or URL can come from a locale file).

## The one-line installer: what you are trusting

`irm https://xhydra.fr/bfo | iex` runs a script from a web server, which is a trust decision you should make knowingly:

- **You trust `xhydra.fr` to serve the right script.** The script is [`install/bfo.ps1`](install/bfo.ps1) in this repository; read it before running it, or fetch it with `$env:BFO_NO_LAUNCH = '1'` (download and verify only, nothing starts) and read the unpacked files.
- **The script then trusts GitHub** to serve the release you asked for, over HTTPS from `github.com/TahaHydra/Brave-Free-Origin/releases`, and refuses to run anything whose SHA-256 differs from the checksum GitHub records for that exact file (or when no checksum is available). That protects against a corrupted or tampered *download*; it cannot protect against a compromised repository account or a compromised web server, which is inherent to any pipe-to-shell installer.
- To take the website out of the picture, use the **portable ZIP** from the Releases page and compare it with `SHA256SUMS.txt`, or pin a release with `$env:BFO_VERSION = 'v2.0'`.
- The script never changes your PowerShell execution policy (the bypass is passed to one child process), never disables or excludes anything from Windows security, and removes its temporary folder when you close the app. It keeps a small log in `%LOCALAPPDATA%\Brave-Free-Origin\logs`.

## Reporting a vulnerability

Please do **not** open a public issue with exploit details.

- Use GitHub's private reporting: **Security** tab of this repository, then **Report a vulnerability**, if the button is shown.
- If it is not shown, open a public issue titled `Security contact request` **without any details** and a maintainer will reach out to you privately.

Useful details: the version (title bar or `AppVersion`), Windows version, what an attacker needs (local user? network position? a crafted locale or config file?), what they gain, and steps to reproduce. You will get an acknowledgement, and credit in the release notes if you want it.

Examples of things that count: a locale or exported config file that makes the app write something it should not, a path that lets a non-administrator influence what the elevated process runs, a way to make the installer run an unverified download, a hosts-file edit that damages entries it does not own.

Examples of things that do not: "Windows shows a UAC prompt" (by design), "antivirus flags a PowerShell script that writes policies" (see the README FAQ), or Brave's own behaviour.
