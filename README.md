# ModCatalogue

The live mod list for Switchboard's **Get mods** tab.

Switchboard fetches `mods.json` from this repository's `main` branch on every check, so adding
a mod means editing that file — not cutting a Switchboard release. Merging here reaches users
immediately, which is also why the file is validated strictly: anything unexpected rejects the
whole file and Switchboard falls back to the list compiled into it, saying so on its status line.

Setting it up — the app, the two services and the credentials — is in [SETUP.md](SETUP.md).

## The file

One JSON object with a schema version and an array of mods:

```json
{
  "schemaVersion": 1,
  "mods": [
    {
      "owner": "swyf-modding",
      "repo": "AI-Backend",
      "displayName": "AI Backend",
      "summary": "Routes the game's AI calls to your own LLM.",
      "files": [
        { "fileName": "ScamWYF.AiBackend.dll", "folder": "plugins", "expectsPluginAttribute": true },
        { "fileName": "ScamWYF.Modding.Core.dll", "folder": "core", "expectsPluginAttribute": false }
      ]
    }
  ]
}
```

| Field | Required | Rules |
|---|---|---|
| `schemaVersion` | yes | Must be `1`. Anything else and older Switchboard versions refuse the file rather than guess at it |
| `owner` | no | A GitHub account name. Defaults to `swyf-modding` when absent |
| `repo` | yes | A GitHub repository name: letters, digits, `.`, `-`, `_` — no URLs, no slashes |
| `displayName` | yes | Up to 80 characters, shown in the list |
| `summary` | yes | Up to 500 characters, shown in the list. Describe what the mod does, not which other mods exist — the list grows and numbering it here rots |
| `files[].fileName` | yes | A bare `.dll` name: no folders, no `..`, nothing but the file. It becomes a file under the game folder, so this is enforced, not advised |
| `files[].folder` | yes | `plugins` for a mod, `core` for the shared library. Nothing else is accepted |
| `files[].expectsPluginAttribute` | yes | `true` for a mod (BepInEx will not load it without `[BepInPlugin]`), `false` for the shared library, which deliberately has none |
| `postInstall` | no | Up to four optional setup steps, offered one by one after installing — see below. Absent means none |
| `approvedVersion` | no | The release tag a reviewer actually looked at, e.g. `v1.5.0`. See **Pinning and capabilities** |
| `files[].sha256` | no | SHA-256 of that file in the approved release, recorded at review time |
| `files[].capabilities` | no | What that file can reach outside the game process, as reported by `tools/scan-capabilities.ps1` |
| `files[].bepInPlugin` | no | What the file's `[BepInPlugin]` attribute says, as `guid \| name \| version`. Absent when the file is not a plugin |
| `postInstall[].sha256` | no | SHA-256 of that setup script in the approved release. Required whenever `approvedVersion` is set |

Keep entries alphabetical by repository name. At most 64 mods and 16 files per mod — caps, not targets.

The file has one shape: two spaces, LF endings, no byte order mark, and the fields in the order
above. `tools/catalogue-rules.ps1` writes it that way, so a change to the catalogue is a change
to the catalogue and not to the formatting.

### The rules are written down once

`tools/catalogue-rules.ps1` holds the rules — the lengths, the names, the caps, what a pinned
entry has to pin. The submission tool, the gate and the schema check all read them from there,
so a rule in two places cannot end up disagreeing with itself.

```powershell
./tools/check-catalogue.ps1                # is mods.json a catalogue Switchboard will accept?
./tools/check-catalogue.ps1 -Entry ./entry.json   # is this one entry a valid entry?
./tools/test-catalogue.ps1                 # do the rules still do what they say they do?
```

The check is the shape of the file, and it costs nothing: no network, no release, no code. A
catalogue with a problem in it is refused whole — Switchboard falls back to the list it was
built with — so one bad entry unlists every mod rather than one.

The test is for the rules themselves, which are the part of this repository that can be wrong
without anybody noticing for weeks. It runs in CI and needs nothing but the repository.

### Optional setup steps

For what the download cannot do by itself: a stream mod's ChatBridge, which talks to Twitch and is
configured per machine, is the case this exists for. Each step names a script shipped **inside the
release zip** and a description shown in the prompt:

```json
"postInstall": [
  {
    "script": "setup-chatbridge.ps1",
    "description": "Installs and configures ChatBridge so the stream mod can read chat. Skipping leaves the mod installed but chat features off."
  }
]
```

| Field | Rules |
|---|---|
| `script` | A bare `.ps1` name — no folders, no `..` — resolved against the unpacked download. At most 64 KB, since Switchboard shows it before asking |
| `description` | Up to 280 characters. Say what it does and what skipping costs; it is shown verbatim |

Switchboard offers each step separately after the files are installed, shows the script, and defaults
to skipping — denying everything leaves the install as it was. A declared script the release does not
contain fails the install rather than being fetched from anywhere else. Scripts receive the game
folder as `-GameDir` and run with the download as their working directory.

A setup step belongs to the mod, not to the submission: when a mod that already has one is submitted
again, the step carries over rather than being quietly dropped. If the release no longer holds the
script, the step is dropped and the submission says so.

## Getting your mod listed

**Send it from the website.** The Submit page takes an owner, a repository and a release, and
reads the rest from GitHub: that the release is one Switchboard can install from, that it holds a
zip, and which files are inside it. The entry is built from that, and the checks are shown as they
are made. Sending it is one click, and you are not asked to write a pull request.

What happens after you send it:

1. **The release is downloaded and the code is read.** `tools/submission.ps1` fetches the release
   and runs `tools/scan-capabilities.ps1` over it — the same scan `verify-catalogue.ps1` uses — so
   the entry records each file's hash and what it can reach. A capability that appears between two
   releases cannot pass unnoticed.
2. **The entry is checked against the code.** Every file the entry names has to be in the release
   and at the top of it, every assembly in the release has to be named by the entry, the shared
   library has to be routed to `core`, every plugin has to carry the `[BepInPlugin]` attribute the
   loader reads with a version the loader can parse, and every setup step has to name a script the
   release really holds. Half an entry is how a mod ends up installed with its library missing.
3. **Everything found is written to the issue**, in one comment: the files with their hashes and
   capabilities, the setup steps, and what the review made of it. A re-run edits that comment
   rather than adding another.
4. **If it all passes, a pull request is opened** with the checked entry, as the project's bot.
   If anything does not pass, nothing is opened: the comment says what is wrong, and a maintainer
   decides what happens next.

The merge is still a person's. A catalogue is a list of code people install, and the step that
puts an entry in it is one somebody should be able to see and undo.

### For a maintainer

The bot is a reviewer's tool: the checks and the review are information, and the commands are
only answered for people with write access.

| Comment on the issue | What it does |
|---|---|
| `/recheck` | runs the checks and the review again, edits the comment, and opens the pull request if it now passes |
| `/create-pr` | opens the pull request anyway, when the review was unsure |
| `/create-pr force` | opens it even though the review refused |

`/recheck` is the useful one after an author publishes a fixed release: the entry re-pins to it,
and a pull request that is already open is updated rather than duplicated.

The issue also carries labels, so the list says what is waiting: `review: ok`, `review: unsure`,
`review: refuse`, `review: failed`, and `pr: opened`.

The listing can also be reviewed by a model, which reads the scan results and the entry and says
whether the summary describes what the code does. It is not a safety verdict and does not pretend to
be one; it holds a submission back when it is unsure, and a submission that is not listed is a
nuisance while one that is listed and should not have been is a mod running in somebody's game.

Your mod must already be installable by Switchboard's rules, because the entry only *names* it —
the checks below still apply at install time:

1. **A public GitHub repository with versioned releases.** Switchboard reads `releases/latest`,
   which ignores prereleases, so publish finished releases. Every release needs a downloadable
   `.zip` asset; a release with no zip cannot be installed from and is reported as such.
2. **The files at the top of the zip.** Switchboard looks for `YourMod.dll` by name in the folder it
   unpacked the download into, and nowhere else. A release that puts its dll in a folder inside the
   zip installs a mod with a file missing, and the submission is refused rather than listed.
3. **Plugin DLLs the loader will actually load.** Each one carries a `[BepInPlugin]` attribute
   whose version BepInEx can parse: two to four dot-separated numbers, no letters, no `+` or `-`.
   A SemVer build-metadata version (`1.2.3+g0a1b2c3`) is valid SemVer and unloadable by BepInEx —
   Switchboard flags it in the list rather than installing something that silently does nothing.
4. **The shared library routed to `core`, if you ship one.** `ScamWYF.Modding.Core.dll` goes in
   `core` with `expectsPluginAttribute: false`. In `plugins` the chainloader would try to load it
   as a plugin and the install would break in a way nothing explains.
5. **A display name and an honest summary.** Say what the mod does. The install confirmation shows
   the files, their versions read out of the binaries, and anything they would replace — there is
   no field here that overrides what is actually in the download.

Third-party repositories are welcome: set `owner` to your account. Switchboard marks those
entries with their owner in the list and names the repository again in the install confirmation,
because unlike the project's own releases there is no shared review behind them.

### Doing it by hand instead

An entry is a pull request editing `mods.json`, and it can still be made that way. The checks the
website runs are the same ones `tools/submission.ps1` runs, so an entry written by hand is held to
exactly the same rules — the difference is only that the file names are typed rather than read out
of the release, and that the hashes and capabilities have to be filled in by hand or by
`tools/scan-capabilities.ps1`.

Check the result before sending it:

```powershell
./tools/check-catalogue.ps1 -Entry ./my-entry.json
```

## Pinning and capabilities

Four optional fields record what was actually reviewed. They are **additive**: `schemaVersion`
stays at `1`, and a Switchboard older than them ignores them and installs `releases/latest` as it
always did.

A Switchboard that does read them installs the release the entry names rather than the newest one,
hashes every file as it unpacks it, and refuses the install if a hash does not match. The list says
`yes` for a fully pinned entry and `no` for one that is not, so the difference between a reviewed
release and a repository someone typed into a list is visible where a person is choosing.

```json
{
  "approvedVersion": "v0.1.0",
  "files": [
    {
      "fileName": "SwyfModManager.dll",
      "folder": "plugins",
      "expectsPluginAttribute": true,
      "sha256": "491f4a169888b8a0e120aa304c15cc4964be68c627b208c8a0f59df4e5750385",
      "capabilities": ["base64", "dynamic-code", "filesystem-read", "filesystem-write", "process"],
      "bepInPlugin": ["xofa.swyf.modmanager | Mod Manager | 0.1.0"]
    }
  ]
}
```

### Why not scan for suspicious strings

Because it does not work. A mod can build a command at runtime and base64 it, and the string
never appears in the file. One listed mod legitimately does exactly that — scanning its strings
returns `powershell.exe` and `*.dll`, and nothing else.

Method references cannot be hidden that way: the callee is a metadata token, not text. So
`tools/scan-capabilities.ps1` walks the IL and reports which host-reaching APIs an assembly
references.

| Capability | Means the file can |
|---|---|
| `process` | start other programs |
| `network` | make network connections |
| `filesystem-read` / `filesystem-write` | read or change files |
| `native-interop` | call native code (P/Invoke, `Marshal`) |
| `dynamic-code` | load or generate code at runtime. Near-universal in Unity modding, so low signal on its own |
| `base64` | encode or decode base64 |
| `registry`, `environment` | read the registry or environment |
| `binary-serialization` | use `BinaryFormatter` |

A pinned entry must pin **everything it installs**, including setup scripts. A setup step is
PowerShell that runs on the machine, shipped in the same replaceable release asset as the DLLs,
and it is the only catalogue-declared thing that reaches a shell — so leaving it unpinned while
calling the release reviewed would put the loudest part of an install outside the only check. The
Switchboard refuses an `approvedVersion` whose files or scripts are missing a hash, rather than
quietly treating it as reviewed.

**This is not a safety verdict.** Most of these are things mods legitimately need — a mod that
installs other mods has to write files, and this one has to start a process. The point is that a
capability *appearing where it was not before* is impossible to miss.

### The gate

`tools/verify-catalogue.ps1` downloads each pinned release, checks the hash, rescans, and fails
if the bytes or the capabilities moved. It also fails if the catalogue does not follow the rules,
if a pinned file is not at the top of the download, if the shared library is routed wrongly, if a
plugin's `[BepInPlugin]` attribute changed, or if a setup script changed. CI runs it on every pull
request and weekly.

The weekly run is the one that earns its keep: a git tag can be moved and a release asset can be
replaced after the fact, so a pin that verified at merge time does not stay true by itself.

```powershell
./tools/verify-catalogue.ps1              # the gate
./tools/verify-catalogue.ps1 -Update      # re-pin everything to current latest, then review the diff
./tools/verify-catalogue.ps1 -Refresh     # re-read the pinned releases, keeping the pins
./tools/scan-capabilities.ps1 -Path x.dll -Detail
./tools/check-catalogue.ps1               # is the file itself a valid catalogue?
./tools/submission.ps1 -Body $body        # check a submission and write the new catalogue
```

When a mod publishes a new release the gate fails, which is intended: someone reads the diff and,
if it is fine, re-pins. A capability change is a prompt to look, not an accusation.

The gate keeps going when one mod cannot be reached. A release that GitHub will not answer for,
or a download that stalls, is reported as unchecked rather than as fine — and the other mods are
still checked, because one unreachable repository is not a reason to stop looking at the rest.

`-Refresh` is for the other case: the pin is right, but the catalogue does not yet say everything
the release says — a plugin that has since declared what it is, say. It reads the pinned releases
again and rewrites what they record, without moving the pin to a different release.

`tools/submission.ps1` is the other half: it is what the workflow runs when a submission arrives.
It downloads the release, reads the code, checks the entry against both, and writes the new
catalogue and a report. It commits nothing — the workflow opens the pull request from what it
writes, so a maintainer still merges it.

```powershell
./tools/submission.ps1 -Body (Get-Content -Raw submission.md) -OutDir ./out
./tools/submission.ps1 -BodyFile ./submission.md -CheckOnly   # check it and write nothing
```

## The bot

Two things here act on GitHub without a person pressing anything: the website's
submission service opens the submission issue, and the submission workflow opens the
pull request. Both do it as a GitHub App, not as a personal access token.

That is not a preference. A pull request opened with the workflow's own `GITHUB_TOKEN`
does **not** trigger the workflows that would check it — GitHub suppresses events caused
by that token — so the gate would never run on a submission. An app's installation token
has no such restriction. It also expires within the hour, and it can do only what the app
was granted, on the repository it is installed on, which is a better thing to have lying
around than somebody's token with `repo` on it.

One app is enough for both halves:

| Permission | Why |
|---|---|
| Issues: read and write | The submission service opens the submission issue |
| Contents: read and write | The workflow pushes the entry's branch |
| Pull requests: read and write | The workflow opens and updates the pull request |

It is installed on this repository only, and the workflow's token is scoped to this
repository even though the installation may be wider.

**Settings that make it work.** A repository variable `BOT_APP_CLIENT_ID` (the app's
client id, safe to keep in plain sight) and a repository secret `BOT_APP_PRIVATE_KEY`
(the `.pem` GitHub gave you once). The service that opens the issue uses the same app;
its configuration is in `website/worker/README.md`.

### Reading other people's repositories

The app cannot see them. An installation token is scoped to the repositories the app is
installed on, and the mod being submitted is usually not one of them — so the two steps
that read it, the scan and the review, take a different credential: a repository secret
`BOT_READ_TOKEN`.

A classic token with **no scopes ticked** is enough. It writes nothing; public read needs
no permission, and its only other job is to raise the API limit from 60 requests an hour
to 5000. A fine-grained token with no repository access works too.

Without it those steps run unauthenticated, which works and is slower — an hour with
more than about thirty submissions in it would hit the limit. The app's token is
deliberately **not** used as a fallback: it would be refused by a repository it does not
know, and the failure reads as a missing release rather than as a missing permission.

So the split is: **the app writes** (issues, commits, pull requests) and **the read token
reads** (releases, source, the catalogue). The writes are the ones that need a durable
identity and an audit trail; the reads are the bulk of the requests, and they are the
part a public read token can do.

## Trust

Listing here is curation, not a safety verdict. A merged entry means someone with merge access
chose to point at that repository — nothing more.

The SHA-256 that GitHub publishes alongside an asset is computed over whatever the author
uploaded, so it catches corruption in transit, not substitution: a malicious release gets a
perfectly valid digest. The `sha256` recorded here is different in kind, because it is written
down at review time — it says *this is the file someone looked at*, which is the claim that
actually matters.

What it still cannot do is vouch for a first submission that was malicious from the start, or for
an author's account being compromised. Switchboard downloads over https, asks before writing
anything into the game folder, and names third-party repositories in the confirmation. Only
install mods from authors you trust, listed or not.
