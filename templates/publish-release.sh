#!/usr/bin/env bash
# Publish a plugin release to the public distribution repository.
#
# Copy this into the plugin repository as scripts/publish-release.sh and make it
# executable. It derives the plugin slug from the origin remote, so it needs no
# per-repository editing.
#
#   scripts/publish-release.sh                 # newest release, channel from the tag
#   scripts/publish-release.sh --tag v1.2.0
#   scripts/publish-release.sh --tag v1.2.0-beta.1
#   scripts/publish-release.sh --tag v1.2.0 --dry-run
#
# Needs: gh (authenticated), unzip, shasum or sha256sum.
#
# In CI the token is scoped to the distribution repository, so it cannot read the
# private development release. Set DEV_TOKEN for that half; the script falls back
# to the one gh is using when it is not set.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
slug="$(basename "$(git -C "$root" remote get-url origin 2>/dev/null || echo "$root")" .git)"
dev_repo="${DEV_REPO:-memberminderpro/$slug}"
dist_repo="${DIST_REPO:-memberminderpro/wp-plugin-releases}"
tag=""
channel=""
dry_run=0

while [ $# -gt 0 ]; do
	case "$1" in
		--tag) tag="$2"; shift 2 ;;
		--channel) channel="$2"; shift 2 ;;
		--dev-repo) dev_repo="$2"; shift 2 ;;
		--dist-repo) dist_repo="$2"; shift 2 ;;
		--dry-run) dry_run=1; shift ;;
		-h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

dev_gh() {
	if [ -n "${DEV_TOKEN:-}" ]; then
		GH_TOKEN="$DEV_TOKEN" gh "$@"
	else
		gh "$@"
	fi
}

# The version the built artifact claims. Understands a plugin header anywhere in
# the plugin folder, and a version constant in an mu-plugin bootstrap or a root
# loader.
read_version() {
	local zip="$1" entry version

	while IFS= read -r entry; do
		version="$(unzip -p "$zip" "$entry" 2>/dev/null \
			| grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' \
			| sed -E 's/.*Version:[[:space:]]*([^[:space:]]+).*/\1/')"
		[ -n "$version" ] && { echo "$version"; return 0; }
	done < <(unzip -Z1 "$zip" | grep -E "^${slug}/[^/]+\.php$" || true)

	while IFS= read -r entry; do
		version="$(unzip -p "$zip" "$entry" 2>/dev/null \
			| grep -m1 -E "define\( *'[A-Z0-9_]*VERSION'" \
			| sed -E "s/.*'([0-9][^']*)'.*/\1/")"
		[ -n "$version" ] && { echo "$version"; return 0; }
	done < <(unzip -Z1 "$zip" | grep -E "^(${slug}/plugin\.php|${slug}\.php)$" || true)

	return 1
}

if [ -z "$tag" ]; then
	tag="$(dev_gh release view --repo "$dev_repo" --json tagName --jq .tagName)"
fi

version="${tag#v}"

if [ -z "$channel" ]; then
	case "$version" in
		*-*) channel=beta ;;
		*) channel=stable ;;
	esac
fi

# A repository with no commits cannot hold releases, so seed it once.
if [ "$(gh repo view "$dist_repo" --json isEmpty --jq .isEmpty 2>/dev/null || echo false)" = "true" ]; then
	echo "Seeding $dist_repo with a README so it can hold releases."
	seed="$(printf '%s\n' \
		'# WordPress plugin releases' \
		'' \
		'Public distribution feed: update manifests and release zips only. See' \
		'docs/adding-a-plugin.md.' | base64 | tr -d '\n')"
	gh api --method PUT "repos/$dist_repo/contents/README.md" \
		-f message="chore: seed the release feed" \
		-f content="$seed" >/dev/null
	sleep 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Fetching $slug $tag from $dev_repo"
dev_gh release download "$tag" --repo "$dev_repo" --pattern '*.zip' -D "$work" --clobber >/dev/null

zip_file="$(find "$work" -maxdepth 1 -name '*.zip' | head -1)"

if [ -z "$zip_file" ]; then
	echo "That release has no zip asset." >&2
	exit 1
fi

if command -v shasum >/dev/null 2>&1; then
	sha="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
else
	sha="$(sha256sum "$zip_file" | awk '{print $1}')"
fi

install_version="$(read_version "$zip_file" "$slug" || true)"

if [ -z "$install_version" ]; then
	echo "Could not read a version out of the zip. Add a plugin header or a *_VERSION constant." >&2
	exit 1
fi

if [ "$install_version" != "$version" ]; then
	echo "The zip holds $install_version but the tag says $version. Refusing to publish." >&2
	exit 1
fi

asset_name="$slug-$version.zip"
cp "$zip_file" "$work/$asset_name"
asset="https://github.com/$dist_repo/releases/download/$slug@$version/$asset_name"

manifest="$(printf '{\n  "schema": 1,\n  "plugin": "%s",\n  "channel": "%s",\n  "version": "%s",\n  "released": "%s",\n  "download": "%s",\n  "sha256": "%s"\n}\n' \
	"$slug" "$channel" "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$asset" "$sha")"

echo "$manifest"

if [ "$dry_run" -eq 1 ]; then
	echo "Dry run: nothing published."
	exit 0
fi

release_tag="$slug@$version"
prerelease=""
[ "$channel" = "beta" ] && prerelease="--prerelease"

if gh release view "$release_tag" --repo "$dist_repo" >/dev/null 2>&1; then
	gh release upload "$release_tag" "$work/$asset_name" --repo "$dist_repo" --clobber >/dev/null
else
	# shellcheck disable=SC2086
	gh release create "$release_tag" "$work/$asset_name" \
		--repo "$dist_repo" \
		--title "$slug $version ($channel)" \
		--notes "$slug $version, published from the private development repository." \
		$prerelease >/dev/null
fi

path="plugins/$slug/$channel/latest.json"
encoded="$(printf '%s' "$manifest" | base64 | tr -d '\n')"
existing="$(gh api "repos/$dist_repo/contents/$path" --jq .sha 2>/dev/null || true)"

if [ -n "$existing" ]; then
	gh api --method PUT "repos/$dist_repo/contents/$path" \
		-f message="release: $slug $version ($channel)" \
		-f content="$encoded" \
		-f sha="$existing" >/dev/null
else
	gh api --method PUT "repos/$dist_repo/contents/$path" \
		-f message="release: $slug $version ($channel)" \
		-f content="$encoded" >/dev/null
fi

echo "Published $slug $version to $channel:"
echo "  https://raw.githubusercontent.com/$dist_repo/HEAD/$path"
