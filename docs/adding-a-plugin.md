# Adding a plugin to the release feed

Everything needed to take a plugin from "private source repository" to "sites
update themselves". Work through it in order; the checklist at the end is the
short version.

- [1. How the pieces fit](#1-how-the-pieces-fit)
- [2. What the plugin needs before it can be published](#2-what-the-plugin-needs-before-it-can-be-published)
- [3. Publish a tag from the source repository](#3-publish-a-tag-from-the-source-repository)
- [4. Wire it into the tag workflow](#4-wire-it-into-the-tag-workflow)
- [5. The manifest](#5-the-manifest)
- [6. Channels: stable and beta](#6-channels-stable-and-beta)
- [7. The consumer side: what the plugin must do to update itself](#7-the-consumer-side-what-the-plugin-must-do-to-update-itself)
- [8. Tokens and permissions](#8-tokens-and-permissions)
- [9. Rolling back and pinning a site](#9-rolling-back-and-pinning-a-site)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Checklist](#11-checklist)

## 1. How the pieces fit

```
memberminderpro/<plugin>                  private   source, PRs, CI, the real release
memberminderpro/wp-plugin-releases        public    manifests + zips, nothing else
```

A release happens twice: once in the source repository (tag, GitHub release, zip)
and once here (the same zip, under a stable URL, plus a manifest naming it). The
second step is what lets a site update without a token: `raw.githubusercontent.com`
and GitHub release assets are readable by anyone, including a WordPress site with
no credentials.

Three consequences worth internalising:

- **The manifest is the contract.** Whatever the manifest says is what every
  site on that channel will install. A wrong version number here reaches
  production.
- **Nothing is secret.** The zips are GPL code, published on purpose.
- **Write access here is production access.** Whoever can write to this
  repository can ship code to every site following a feed. Keep it short.

## 2. What the plugin needs before it can be published

1. **A version number in the built artifact that matches the tag.** The publish
   script reads it out of the zip and refuses to publish a mismatch. Either of
   these is recognised:

   - a plugin header with `Version:` in the main file
     (`mmp-activity-log/class-…php` style, or `my-plugin/my-plugin.php`), or
   - a constant, e.g. `define( 'MMP_AL_VERSION', '1.2.0' );`

   Put it in **one place** and have the rest of the code read that value. If two
   copies exist, one will be forgotten by a release tool and the artifact will lie
   about its version.

2. **A build that produces an installable zip**, run in CI, not on a laptop. In
   our repositories that is `scripts/package.sh`, invoked by the tag workflow.

3. **A tag that Release Please creates.** The tag is what starts everything; do
   not hand-push tags as a rule (see the note in the source repo's CONTRIBUTING
   about tag pushes needing to be on their own).

4. **The release app installed on the repository**, the same app used for Release
   Please, so CI can mint a token (see §8).

## 3. Publish a tag from the source repository

Copy `templates/publish-release.sh` into the source repository as
`scripts/publish-release.sh` and make it executable:

```sh
chmod +x scripts/publish-release.sh
```

It needs `gh`, `unzip`, `curl`-free (it uses `gh`), and `shasum` or `sha256sum`.
It derives the plugin slug from the repository's `origin` remote, so it needs no
configuration.

```sh
scripts/publish-release.sh --dry-run                 # newest release, prints the manifest
scripts/publish-release.sh --tag v1.2.0 --dry-run    # a specific tag
scripts/publish-release.sh --tag v1.2.0              # publish
scripts/publish-release.sh --tag v1.2.0-beta.1       # publishes to beta automatically
```

What it does, in order:

1. resolves the tag (newest release if not given) and the channel from the tag,
2. downloads that release's zip from the private repository,
3. reads the version out of the zip and refuses the publish if it differs from the tag,
4. hashes the zip,
5. creates or replaces the release `<slug>@<version>` in this repository and
   uploads the zip as `<slug>-<version>.zip`,
6. writes `plugins/<slug>/<channel>/latest.json`,
7. prints the raw URL to verify.

Dry run stops after step 4, so it is safe to run anywhere.

## 4. Wire it into the tag workflow

The tag workflow already builds and publishes the zip in the source repository.
Two steps go after that, at the end of the `publish` job. Copy them from
`templates/release-publish-step.yml`; this is what they do:

```yaml
      - name: Token for the distribution repository
        id: dist
        continue-on-error: true
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.RELEASE_APP_ID }}
          private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
          owner: memberminderpro
          repositories: wp-plugin-releases

      - name: Publish to the distribution repository
        if: steps.dist.outputs.token != ''
        env:
          GH_TOKEN: ${{ steps.dist.outputs.token }}
          DEV_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: ${{ github.ref_name }}
        run: |
          set -euo pipefail
          if ! gh api "repos/memberminderpro/wp-plugin-releases" >/dev/null 2>&1; then
            echo "::notice::wp-plugin-releases is not reachable with this app; skipped publishing to the feed."
            exit 0
          fi
          scripts/publish-release.sh --tag "$TAG"
```

Three details that matter:

- **Two tokens.** `GH_TOKEN` is the app token, scoped to the feed repository; it
  cannot read the private release. `DEV_TOKEN` is the workflow's own
  `GITHUB_TOKEN`, which can. The script uses `DEV_TOKEN` for the development
  repository and `GH_TOKEN` for the feed. Getting this wrong looks like
  `release not found`.
- **`continue-on-error` on the token step**, plus the reachability check, so a
  repository the app cannot see produces a notice instead of a red release.
- **No secrets in the repository.** The app id and key are organisation secrets.

If the app is not an option, replace the two steps with one that uses a
fine-grained token stored as the repository secret `DIST_TOKEN`, with
`Contents: read and write` on `wp-plugin-releases` and `Contents: read` on the
source repository, and pass it as both `GH_TOKEN` and `DEV_TOKEN`.

## 5. The manifest

```json
{
  "schema": 1,
  "plugin": "mmp-activity-log",
  "channel": "stable",
  "version": "1.2.0",
  "released": "2026-11-24T18:29:01Z",
  "download": "https://github.com/memberminderpro/wp-plugin-releases/releases/download/mmp-activity-log@1.2.0/mmp-activity-log-1.2.0.zip",
  "sha256": "ef899524ee10e7edfe3fd54ab2d26a19acf344c06b6f352a69413cd8d2ac23b7"
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `schema` | yes | `1`. Bump only if the shape changes in a breaking way. |
| `plugin` | yes | The slug, matching the folder and the zip name. |
| `channel` | yes | `stable` or `beta`. A site only reads its own channel. |
| `version` | yes | No leading `v`. Compared with `version_compare()`. |
| `released` | yes | UTC timestamp, for humans and for "when did this ship". |
| `download` | yes | Absolute https URL to the zip. |
| `sha256` | yes | Lowercase hex. A consumer must check it before unpacking. |

Consumers may also accept `url` instead of `download`, and ignore unknown fields,
so additions are safe.

The URL is served from `raw.githubusercontent.com` on the `HEAD` ref. It caches
for about five minutes; after a publish, wait that long before concluding anything
is broken.

## 6. Channels: stable and beta

The tag decides. Nothing else.

| Tag | Channel | Notes |
| --- | --- | --- |
| `v1.2.0` | stable | what production sites receive |
| `v1.2.0-beta.1` | beta | opt-in sites only |

Rules that keep this sane:

- **A beta never becomes stable by moving files.** When the beta is good, cut the
  next stable release from the merged code: the beta branch merges, Release Please
  produces `v1.2.0`, and that publishes to stable. Publishing the same version
  number to both channels is how two different zips end up claiming to be the same
  release.
- **Beta sites follow the beta channel only.** They do not fall back to stable
  when beta has no newer manifest; they simply stay where they are.
- **Only the channel's manifest moves.** Publishing a stable release leaves beta
  untouched, and the reverse.

## 7. The consumer side: what the plugin must do to update itself

A normal plugin can use WordPress's own updater with
`pre_set_site_transient_update_plugins`. A must-use plugin cannot — WordPress never
looks at `mu-plugins/` — so it needs its own updater. Both end up doing the same
five things:

1. **Read the manifest** for its channel, on a schedule (we use twice daily) with
   a timeout and a sensible `User-Agent`.
2. **Compare** `version_compare( $manifest['version'], $installed, '>' )`.
3. **Download** to a temporary file.
4. **Verify** the `sha256` before unpacking, then check that the unpacked tree has
   the version the manifest promised.
5. **Install with a way back**: copy or rename the current files aside, put the new
   ones in, read the version back out of the installed copy, delete the backup only
   after that, and restore it on any failure.

Two more things worth copying from `mmp-activity-log`:

- **Refuse to run when the site cannot write files directly**
  (`get_filesystem_method() !== 'direct'`), with a message saying so, rather than
  half-installing.
- **Log the update** into whatever audit trail the plugin has, with the versions
  before and after. "When did this site move to 1.2.0" should be answerable.

A site can be pinned without a fork:

```php
// Point this site at one specific build and leave it there.
add_filter( 'mmp_al_release_endpoint', fn() => 'https://example.com/pinned.json' );
```

## 8. Tokens and permissions

| Actor | Needs | Why |
| --- | --- | --- |
| The release app | installed on the source repository | mint the app token in CI |
| The release app | installed on `wp-plugin-releases` | create releases and commit manifests |
| Workflow `GITHUB_TOKEN` | default | read the private release (`DEV_TOKEN`) |
| Sites | nothing | the feed is public |

If the app is not installed on the feed repository, the publish step prints a
notice and skips; the source repository's release still succeeds. That is
deliberate: a missed feed publish should not fail a release, but it also should
not pass silently, which is why the notice exists and why this guide tells you to
check the feed after the first tag.

## 9. Rolling back and pinning a site

- **Roll back the feed**: publish a higher version containing the old code. That
  is the only rollback every consumer is guaranteed to act on, because they only
  ever move forward.
- **Roll back one site**: point it at a manifest you control with
  `mmp_al_release_endpoint`, or set it to the other channel if that is where the
  working build is.
- **Keep a site still**: turn automatic updates off in the plugin's settings, or
  define `MMP_AL_DISABLE_AUTO_UPDATE` — that also protects against a bad manifest.
- **The manifests are versioned.** `git log` in this repository shows what each
  channel pointed at, and when, which is the incident timeline.

## 10. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Manifest URL 404, right after a publish | `raw.githubusercontent.com` caches ~5 min | wait, then re-check |
| Manifest URL 404, always | wrong slug or channel path, or the manifest commit never landed | `gh api repos/memberminderpro/wp-plugin-releases/contents/plugins/<slug>/<channel>/latest.json` |
| `release not found` in CI | the token cannot read the private source release | pass `DEV_TOKEN`; the app token alone is scoped to the feed |
| `Repository is empty` on upload | GitHub refuses release assets in a repository with no commits | the script seeds a README; if the repo was emptied by hand, commit anything first |
| Download URL 404s but the asset exists | the asset name and the manifest name disagree | publish with the script; it uploads `<slug>-<version>.zip` |
| Site reports `The download does not match the checksum` | partial download, or the manifest was edited by hand | re-publish; never hand-edit a manifest |
| Site says `Already on the latest release` forever | the tag's version and the artifact's version differ | check the marker block around the version constant; the tag job refuses a mismatch |
| Site says it cannot write files directly | shared host with FTP-credential filesystem | update that site by hand; it cannot self-update |
| Everything green, site still old | the site's check has not run yet | run `wp cron event run <hook>` on the site, or wait for the twice-daily check |

## 11. Checklist

Source repository:

- [ ] Version lives in one place, with a release tool that updates it
- [ ] `scripts/package.sh` builds the zip in CI
- [ ] `scripts/publish-release.sh` copied in and executable
- [ ] Tag workflow has the two publish steps (§4)
- [ ] Release app installed on the source repository
- [ ] Release app installed on `wp-plugin-releases`
- [ ] First tag published, and the manifest URL checked

Feed:

- [ ] `plugins/<slug>/stable/latest.json` exists and names the right version
- [ ] The zip downloads, and its `sha256` matches the manifest
- [ ] `beta/latest.json` exists only when there is a real beta

Consumer:

- [ ] Updater reads the manifest for its channel
- [ ] `sha256` checked before unpacking
- [ ] Install backs up, verifies, and restores on failure
- [ ] Update is logged with both versions
- [ ] A site has been watched through one real update
