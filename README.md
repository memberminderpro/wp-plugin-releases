# WordPress plugin releases

Public distribution feed for Member Minder Pro, LLC WordPress plugins.

Development repositories stay **private**. This repository is **public** and holds
nothing but what a site needs in order to update itself: one small JSON manifest
per plugin per channel, and the release zips as assets of this repository's own
releases.

```
plugins/<plugin>/stable/latest.json      what sites on the stable channel read
plugins/<plugin>/beta/latest.json        what sites on the beta channel read
releases/download/<plugin>@<version>/<plugin>-<version>.zip
```

Nothing here needs a token. A site fetches

```
https://raw.githubusercontent.com/memberminderpro/wp-plugin-releases/HEAD/plugins/<plugin>/<channel>/latest.json
```

and, if the version is newer, downloads the zip named in it and checks its
SHA-256 before installing.

## Adding a plugin

Read **[docs/adding-a-plugin.md](docs/adding-a-plugin.md)**. It covers the source
repository's release workflow, the publishing script, the manifest, the two
tokens, the consumer side, and what to do when something goes wrong.

Templates to copy rather than retype:

- [`templates/publish-release.sh`](templates/publish-release.sh) — publish a tag
- [`templates/release-publish-step.yml`](templates/release-publish-step.yml) — the workflow steps

## Existing plugins

| Plugin | Channels | Notes |
| --- | --- | --- |
| `mmp-activity-log` | stable | must-use plugin, auto-updates itself |

## Publishing by hand

From the plugin's own repository:

```sh
scripts/publish-release.sh --tag v1.2.0 --dry-run   # prints the manifest
scripts/publish-release.sh --tag v1.2.0             # publishes
```

A tag with a hyphen in the version (`v1.2.0-beta.1`) publishes to `beta`; anything
else publishes to `stable`.

## What this repository is not

- Not a copy of any source repository. There is no code here except the zip assets.
- Not a backup. The release in the source repository is the record; this is the
  feed sites read.
- Not a place to commit by hand. The manifests are written by
  `publish-release.sh`; hand edits make the feed disagree with the tag it claims.
