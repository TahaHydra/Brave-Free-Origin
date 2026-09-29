# The one-line installer

`irm https://xhydra.fr/bfo | iex` runs [`install/bfo.ps1`](../install/bfo.ps1). This page explains what the script does, how it is tested, and what has to be true on the web server that serves it.

## What it does

1. Checks the environment: Windows, FullLanguage mode, no Group Policy that only allows signed scripts. Enables TLS 1.2 for Windows PowerShell 5.1.
2. Asks `api.github.com` for the latest release of `TahaHydra/Brave-Free-Origin` (or `$env:BFO_VERSION`, for example `v1.13`).
3. Requires the release asset `Brave-Free-Origin.zip` **and** the SHA-256 that GitHub records for it. No checksum, no run.
4. Downloads the zip into `%LOCALAPPDATA%\Brave-Free-Origin\run\<random id>\`, compares its SHA-256 with GitHub's, and stops (deleting the download) on any difference.
5. Unpacks it, refusing any entry whose path would leave that folder, and requires `Brave-Free-Origin.ps1` inside.
6. Starts `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ...\Brave-Free-Origin.ps1 -BfoSettingsPath ...` with `Start-Process -Verb RunAs -Wait` (skipping `RunAs` when the window is already elevated). The execution-policy bypass exists only for that one child process. `-Lang` is passed when `$env:BFO_LANG` is set.
7. When the app closes, deletes the run folder (and any run folder older than a day left behind by a crash), then reports the outcome: finished, permission prompt declined, or the app's exit code with the log folder.

Options (environment variables, because a piped script cannot take parameters): `BFO_VERSION`, `BFO_LANG`, `BFO_NO_LAUNCH=1` (download, verify and unpack only; prints the folder and keeps the files so you can read them before running `Brave-Free-Origin.bat` yourself).

Design points worth knowing:

- The script never calls `exit` (it would close the user's window under `iex`), removes its own helper functions from the session when it finishes, and is pure ASCII (Windows PowerShell 5.1 guesses the charset of a downloaded script).
- Settings, logs and backups stay where the app always keeps them, so deleting the run folder loses nothing.
- Exit codes: `0` finished, `1` error (explained on screen and logged to `%LOCALAPPDATA%\Brave-Free-Origin\logs\bootstrap-*.log`), `2` the permission prompt was declined. The code is left in `$LASTEXITCODE`.

## Tests

`tools\Test-Bootstrap.ps1` runs the real script against a fake GitHub on `127.0.0.1` (16 tests, Windows PowerShell 5.1 and PowerShell 7): latest and pinned releases, the exact launch arguments, cleanup, download-only mode, a tampered download, a missing checksum, a hostile zip entry, an incomplete zip, unknown release, rate limiting, invalid version text, a declined permission prompt, an app crash, stale folders, and the real `Invoke-Expression` shape driven by environment variables. Nothing leaves the machine, no UAC prompt appears, and nothing outside a temp folder is touched. `BFO_API_BASE` is honoured only for `http://127.0.0.1:<port>` / `localhost`, so it can never redirect a real install to another machine.

What the tests cannot cover is the real UAC prompt: after each change to the launch step, run the one-liner once on a real PC.

## Hosting `https://xhydra.fr/bfo`

The site is a Next.js app on Vercel behind Cloudflare. Requirements for the `/bfo` route:

| Requirement | Why |
| --- | --- |
| HTTPS with a valid certificate, status `200` after at most a couple of redirects | `irm` follows redirects, but not an HTML interstitial |
| `Content-Type: text/plain; charset=utf-8` | `irm` returns a byte array for `application/octet-stream` and `iex` cannot run that; HTML breaks it; without a charset Windows PowerShell 5.1 decodes as Latin-1 |
| Body byte-identical to `install/bfo.ps1` (no BOM, no minification, no injected snippets) | Cloudflare Auto Minify, Rocket Loader and email obfuscation must not rewrite this path |
| Short cache (`Cache-Control: max-age=300`, or `no-cache`) | A fixed installer should reach users within minutes |
| Not blocked for PowerShell user agents | Cloudflare *Bot Fight Mode* or a managed challenge on `/bfo` returns an HTML page and breaks the command. Add a WAF skip rule for the path |

The simplest setup is a redirect that always serves the file from the repository, so the site never holds a copy that can go stale. In `next.config.js`:

```js
async redirects() {
  return [{
    source: '/bfo',
    destination: 'https://raw.githubusercontent.com/TahaHydra/Brave-Free-Origin/main/install/bfo.ps1',
    permanent: false,
  }];
},
```

`raw.githubusercontent.com` serves `text/plain; charset=utf-8`. If you prefer the site to serve the bytes itself, use a route handler that returns the file with the headers above.

The same script works straight from GitHub with no website at all, which is a good fallback and the way to test before the route exists:

```powershell
irm https://raw.githubusercontent.com/TahaHydra/Brave-Free-Origin/main/install/bfo.ps1 | iex
```

### Before you announce it

1. Publish the release that contains this version of the app (push the `v1.13` tag; the Release workflow builds and attaches `Brave-Free-Origin.zip`). The installer downloads the **latest release**, so until v1.13 is published the one-liner would start the old v1.12 app (it works, but it is the old interface and the old policy list).
2. Check the route: `curl.exe -sI https://xhydra.fr/bfo` shows `200` (or a redirect to the raw URL) and `content-type: text/plain`.
3. Run download-only mode against the live route: `$env:BFO_NO_LAUNCH = '1'; irm https://xhydra.fr/bfo | iex`, and confirm `Matches.` appears.
4. Run the real thing once on a clean Windows profile, both from a standard user (UAC asks for an administrator password) and from an administrator account.
5. The README, `SECURITY.md` and the website's Brave Free Origin pages all quote the same command; keep them identical.
