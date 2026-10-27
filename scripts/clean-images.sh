#!/usr/bin/env bash
set -euo pipefail

OPTION="$*"
LIMIT="${2:-0}"
IMAGE=coollabsio/coolify
KEEP_TAGS='^(latest|preview|nightly|v?[0-9]+(\.[0-9]+)*(-(alpha|beta|rc)\.[0-9]+)?)$'
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
MANIFEST_TYPES=application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json
LIST_FILE=scripts/clean-images.tsv
WORK_DIR="$(mktemp -d)"

BOLD=$'\033[1m' BLUE=$'\033[34m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'

heading() { printf '\n  %s%s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '  %sℹ%s %s\n' "$BLUE" "$RESET" "$*"; }
ok() { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$YELLOW" "$RESET" "$*"; }
die() {
	printf '  %s✖%s %s\n' "$RED" "$RESET" "$*" >&2
	exit 1
}

cd "$(dirname "$0")/.."
trap 'rm -rf "$WORK_DIR"' EXIT

main() {
	[[ "$OPTION" =~ ^(--delete( [1-9][0-9]*)?)?$ ]] || die "'$OPTION' is not an option, expected --delete, --delete with a count or none"
	heading "Reading ghcr.io/$IMAGE and docker.io/$IMAGE"
	read_ghcr_versions
	read_dockerhub_tags
	select_kept_tags
	read_kept_manifests
	heading "Selecting what to delete"
	read_unused_manifests
	find_dockerhub_leftovers
	write_list
	delete_manifests
	verify_kept_manifests
}

read_ghcr_versions() {
	local state
	for state in active deleted; do
		gh api --paginate "/orgs/${IMAGE%%/*}/packages/container/${IMAGE#*/}/versions?per_page=100&state=$state" \
			--jq '.[] | [.name, (.id | tostring), (.metadata.container.tags | join(",")), .created_at] | @tsv' > "$WORK_DIR/ghcr-$state.tsv" 2> /dev/null \
			|| die "gh could not list the $state versions of ghcr.io/$IMAGE, it needs read:packages and delete:packages: gh auth refresh -s read:packages,delete:packages"
	done
	ok "ghcr.io/$IMAGE has $(count < "$WORK_DIR/ghcr-active.tsv") versions, $(awk -F '\t' '$3 == ""' "$WORK_DIR/ghcr-active.tsv" | count) of them untagged, and lists $(count < "$WORK_DIR/ghcr-deleted.tsv") deleted ones"
}

read_dockerhub_tags() {
	local token page last="" tag
	token="$(registry_token docker.io pull)"
	: > "$WORK_DIR/dockerhub-tags.txt"
	while :; do
		page="$(curl -sSf --retry 3 -H "Authorization: Bearer $token" "https://registry-1.docker.io/v2/$IMAGE/tags/list?n=1000${last:+&last=$last}" | jq -r '.tags // [] | .[]')" \
			|| die "could not list the tags of docker.io/$IMAGE"
		[ -n "$page" ] || break
		echo "$page" >> "$WORK_DIR/dockerhub-tags.txt"
		last="$(tail -n 1 <<< "$page")"
	done
	head_manifests docker.io "$WORK_DIR/dockerhub-tags.txt" "$WORK_DIR/heads" > "$WORK_DIR/heads.txt"
	[ "$(awk '$1 != 200' "$WORK_DIR/heads.txt" | count)" = 0 ] || die "could not read the digests of the tags of docker.io/$IMAGE"
	while read -r tag; do
		printf '%s\t%s\t%s\t%s\n' "$(header docker-content-digest "$WORK_DIR/heads/$tag")" "$tag" \
			"$(header content-type "$WORK_DIR/heads/$tag")" "$(header content-length "$WORK_DIR/heads/$tag")"
	done < "$WORK_DIR/dockerhub-tags.txt" > "$WORK_DIR/dockerhub.tsv"
	ok "docker.io/$IMAGE has $(count < "$WORK_DIR/dockerhub.tsv") tags on $(cut -f 1 "$WORK_DIR/dockerhub.tsv" | sort -u | count) manifests"
}

select_kept_tags() {
	{ cut -f 3 "$WORK_DIR/ghcr-active.tsv" | tr ',' '\n' && cut -f 2 "$WORK_DIR/dockerhub.tsv"; } | sed '/^$/d' | sort -u > "$WORK_DIR/tags.txt"
	git ls-remote --tags "https://github.com/$IMAGE.git" | sed -n 's|.*refs/tags/||p' | sed 's/\^{}$//; p; s/^v//' | sort -u > "$WORK_DIR/git-tags.txt" \
		|| die "could not list the git tags of github.com/$IMAGE"
	gh pr list --repo "$IMAGE" --state open --limit 1000 --json number --jq '.[] | "pr-\(.number)"' > "$WORK_DIR/pull-requests.txt" \
		|| die "gh could not list the open pull requests of $IMAGE"
	grep -E "$KEEP_TAGS" "$WORK_DIR/tags.txt" > "$WORK_DIR/kept-tags.txt" || true
	grep -xF -f "$WORK_DIR/git-tags.txt" -f "$WORK_DIR/pull-requests.txt" "$WORK_DIR/tags.txt" >> "$WORK_DIR/kept-tags.txt" || true
	sort -u -o "$WORK_DIR/kept-tags.txt" "$WORK_DIR/kept-tags.txt"
	grep -qx latest "$WORK_DIR/kept-tags.txt" || die "found no latest tag, expected it among the tags to keep"
	ok "keeping $(count < "$WORK_DIR/kept-tags.txt") tags: every tag KEEP_TAGS matches, every git tag of github.com/$IMAGE and the tags of open pull requests"
}

read_kept_manifests() {
	local digest tag
	tagged_digests "$WORK_DIR/ghcr-active.tsv" 1 3 > "$WORK_DIR/roots-ghcr.txt"
	tagged_digests "$WORK_DIR/dockerhub.tsv" 1 2 > "$WORK_DIR/roots-dockerhub.txt"
	cut -f 1 "$WORK_DIR/ghcr-active.tsv" > "$WORK_DIR/on-ghcr.txt"
	sort -u "$WORK_DIR/roots-ghcr.txt" "$WORK_DIR/roots-dockerhub.txt" | grep -xF -f "$WORK_DIR/on-ghcr.txt" > "$WORK_DIR/read-on-ghcr.txt" || true
	get_manifests "$WORK_DIR/read-on-ghcr.txt" "$WORK_DIR/kept" || die "could not read the manifests the kept tags point at on ghcr.io"
	find "$WORK_DIR/kept" -type f -exec jq -r '.manifests[]? | "\(input_filename | sub(".*/"; "")) \(.digest) \(.mediaType)"' {} + > "$WORK_DIR/children.txt"
	while IFS=$'\t' read -r digest tag; do
		curl -sSf --retry 3 "https://hub.docker.com/v2/namespaces/${IMAGE%%/*}/repositories/${IMAGE#*/}/tags/$tag" \
			| jq -r --arg root "$digest" '.images[] | "\($root) \(.digest) image"' >> "$WORK_DIR/children.txt" \
			|| die "could not read the manifests $tag points at on docker.io"
	done < <(awk -F '\t' 'FILENAME == ARGV[1] { ghcr[$1]; next } FILENAME == ARGV[2] { root[$1]; next } ($1 in root) && !($1 in ghcr) && !seen[$1]++ { print $1 "\t" $2 }' \
		"$WORK_DIR/on-ghcr.txt" "$WORK_DIR/roots-dockerhub.txt" "$WORK_DIR/dockerhub.tsv")
	! grep -qE 'index|list' <(cut -d ' ' -f 3 "$WORK_DIR/children.txt") || die "a kept index points at another index, expected only images and attestations"
	kept_closure roots-ghcr > "$WORK_DIR/kept-ghcr.txt"
	kept_closure roots-dockerhub > "$WORK_DIR/kept-dockerhub.txt"
	sort -u "$WORK_DIR/kept-ghcr.txt" "$WORK_DIR/kept-dockerhub.txt" > "$WORK_DIR/kept-manifests.txt"
	[ "$(grep -cvxF -f "$WORK_DIR/on-ghcr.txt" "$WORK_DIR/kept-ghcr.txt" || true)" = 0 ] \
		|| die "manifests the kept tags point at are missing from the versions gh listed on ghcr.io, expected every one of them"
	ok "keeping $(count < "$WORK_DIR/kept-ghcr.txt") manifests on ghcr.io and $(count < "$WORK_DIR/kept-dockerhub.txt") on docker.io: the kept tags and every manifest they point at"
}

read_unused_manifests() {
	awk -F '\t' 'FILENAME == ARGV[1] { kept[$1]; next } !($1 in kept) { print $1 }' "$WORK_DIR/kept-manifests.txt" "$WORK_DIR/ghcr-active.tsv" > "$WORK_DIR/unused.txt"
	get_manifests "$WORK_DIR/unused.txt" "$WORK_DIR/unused" || die "could not read the unused manifests on ghcr.io"
	find "$WORK_DIR/unused" -type f -exec ls -ln {} + | awk -v OFS='\t' '{ sub(".*/", "", $NF); print $NF, $5 }' > "$WORK_DIR/bytes.tsv"
	find "$WORK_DIR/unused" -type f -exec jq -r '[(input_filename | sub(".*/"; "")),
		(if .manifests then "index" elif any(.layers[]?; .mediaType == "application/vnd.in-toto+json") then "attestation" else "image" end),
		([.config.size // 0, .layers[]?.size] | add)] | @tsv' {} + \
		| awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { bytes[$1] = $2; next } { print $1, $2, $3 + bytes[$1] }' "$WORK_DIR/bytes.tsv" - > "$WORK_DIR/details.tsv"
	find "$WORK_DIR/kept" "$WORK_DIR/unused" -type f -exec jq -r 'select(.manifests) | .manifests[]
		| [.digest, "\(.platform.os // "unknown")/\(.platform.architecture // "unknown")\(if .platform.variant then "/" + .platform.variant else "" end)",
		(.annotations["vnd.docker.reference.digest"] // "")] | @tsv' {} + \
		| awk -F '\t' -v OFS='\t' '{ platform[$1] = $2; reference[$1] = $3 } END { for (digest in platform) print digest, (reference[digest] in platform) ? platform[reference[digest]] : platform[digest] }' \
			> "$WORK_DIR/platforms.tsv"
	ok "read the $(count < "$WORK_DIR/unused.txt") unused manifests on ghcr.io, their type, platform and size"
}

find_dockerhub_leftovers() {
	local digest
	awk -F '\t' 'FILENAME != ARGV[3] { skip[$1]; next } !($1 in skip) && !seen[$1]++ { print $1 }' \
		"$WORK_DIR/kept-manifests.txt" "$WORK_DIR/ghcr-active.tsv" "$WORK_DIR/ghcr-deleted.tsv" > "$WORK_DIR/deleted.txt"
	head_manifests docker.io "$WORK_DIR/deleted.txt" "$WORK_DIR/leftovers" > "$WORK_DIR/leftovers.txt"
	[ "$(awk '$1 != 200 && $1 != 404' "$WORK_DIR/leftovers.txt" | count)" = 0 ] || die "could not check docker.io for the manifests ghcr.io deleted, expected 200 or 404"
	awk '$1 == 200 { print $2 }' "$WORK_DIR/leftovers.txt" | while read -r digest; do
		printf '%s\t%s\t%s\n' "$digest" "$(header content-type "$WORK_DIR/leftovers/$digest")" "$(header content-length "$WORK_DIR/leftovers/$digest")"
	done > "$WORK_DIR/leftover-details.tsv"
	ok "docker.io still has $(count < "$WORK_DIR/leftover-details.tsv") of the $(count < "$WORK_DIR/deleted.txt") unused manifests ghcr.io deleted"
}

write_list() {
	local total unique
	{
		awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { type[$1] = $2; size[$1] = $3; next } FILENAME == ARGV[2] { platform[$1] = $2; next }
			($1 in type) { print "ghcr.io and docker.io", $2, $1, type[$1], platform[$1], $4, $3, size[$1] }' \
			"$WORK_DIR/details.tsv" "$WORK_DIR/platforms.tsv" "$WORK_DIR/ghcr-active.tsv"
		awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { type[$1] = ($2 ~ /index|list/) ? "index" : "image"; size[$1] = $3; next }
			FILENAME == ARGV[2] { platform[$1] = $2; next } FILENAME == ARGV[3] { tags[$1] = tags[$1] (tags[$1] == "" ? "" : ",") $2; next }
			($1 in type) && !seen[$1]++ { print "docker.io", $2, $1, type[$1], platform[$1], $4, tags[$1], size[$1] }' \
			"$WORK_DIR/leftover-details.tsv" "$WORK_DIR/platforms.tsv" "$WORK_DIR/dockerhub.tsv" "$WORK_DIR/ghcr-deleted.tsv"
		awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[4] { platform[$1] = $2; next } FILENAME != ARGV[5] { skip[$1]; next }
			!($1 in skip) { type[$1] = ($3 ~ /index|list/) ? "index" : "image"; size[$1] = $4; tags[$1] = tags[$1] (tags[$1] == "" ? "" : ",") $2 }
			END { for (digest in type) print "docker.io", "", digest, type[digest], platform[digest], "", tags[digest], size[digest] }' \
			"$WORK_DIR/kept-manifests.txt" "$WORK_DIR/unused.txt" "$WORK_DIR/leftover-details.tsv" "$WORK_DIR/platforms.tsv" "$WORK_DIR/dockerhub.tsv"
	} | awk -F '\t' -v OFS='\t' '{ print ($4 == "index") ? 0 : 1, $0 }' | sort -t $'\t' -k1,1n -k7,7 | cut -f 2- > "$WORK_DIR/rows.tsv"
	total="$(awk -F '\t' '{ sum += $8 } END { print sum + 0 }' "$WORK_DIR/rows.tsv")"
	unique="$({ find "$WORK_DIR/unused" -type f -exec jq -r '(.config // empty), .layers[]? | [.digest, .size] | @tsv' {} + | sort -u | cut -f 2 && cut -f 2 "$WORK_DIR/bytes.tsv"; } \
		| awk '{ sum += $1 } END { print sum + 0 }')"
	{
		printf 'delete from\tversion\tdigest\ttype\tplatform\tcreated\ttags\tsize\treference\n'
		awk -F '\t' -v OFS='\t' -v image="$IMAGE" '{ print $0, (($1 == "docker.io") ? "docker.io/" : "ghcr.io/") image "@" $3 }' "$WORK_DIR/rows.tsv"
		awk -F '\t' -v OFS='\t' -v note="$(human "$total"), $(human "$unique") with every layer counted once" '{ count[$4]++; size += $8 }
			END { print "total", "", NR " manifests", (count["index"] + 0) " indexes, " (count["image"] + 0) " images, " (count["attestation"] + 0) " attestations", "", "", "", size + 0, note }' \
			"$WORK_DIR/rows.tsv"
	} > "$LIST_FILE"
	ok "ghcr.io and docker.io: $(rows 'ghcr.io and docker.io' | count) manifests to delete, $(human "$unique") with every layer counted once"
	ok "docker.io alone: $(rows docker.io | count) manifests to delete, ghcr.io deleted them already or never had them"
	ok "$(count < "$WORK_DIR/rows.tsv") manifests to delete in total, $(human "$total") with the layers of every image counted"
	info "$LIST_FILE lists every manifest to delete with its type, platform, size in bytes and a reference to inspect it, indexes first"
}

delete_manifests() {
	local from version digest type tags status deleted=0
	if [ "$OPTION" = "" ]; then
		info "nothing is deleted, a run with --delete deletes them"
		return
	fi
	[ -n "$DOCKERHUB_USERNAME" ] && [ -n "$DOCKERHUB_TOKEN" ] || die "DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be set to delete manifests on docker.io"
	heading "Deleting"
	while IFS='|' read -r from version digest type tags; do
		if [ "$from" != docker.io ] && ! delete_ghcr_version "$version" "$digest" "$tags"; then
			continue
		fi
		status="$(delete_dockerhub_manifest "$digest")"
		case "$from:$status" in
			*:2??) ok "deleted the $type $BOLD$digest$RESET${tags:+ ($tags)} from $from" ;;
			docker.io:404) ok "docker.io no longer has the $type $BOLD$digest$RESET${tags:+ ($tags)}" ;;
			*:404) ok "deleted the $type $BOLD$digest$RESET${tags:+ ($tags)} from ghcr.io, docker.io does not have it" ;;
			*:403 | *:5??)
				warn "docker.io keeps the $type $digest${tags:+ ($tags)} for now, it answered $status, the next run tries again"
				continue
				;;
			*) die "could not delete the $type $digest${tags:+ ($tags)} from docker.io, it answered $status" ;;
		esac
		deleted=$((deleted + 1))
	done < <(awk -F '\t' -v OFS='|' 'NR > 1 && $1 != "total" { print $1, $2, $3, $4, $7 }' "$LIST_FILE" | limit)
	ok "deleted $deleted manifests, ghcr.io restores them for 30 days, docker.io deletes for good"
}

verify_kept_manifests() {
	[ "$OPTION" != "" ] || return 0
	check_manifests ghcr.io "$WORK_DIR/kept-ghcr.txt"
	check_manifests docker.io "$WORK_DIR/kept-dockerhub.txt"
	ok "every kept tag and every manifest it points at is still on ghcr.io and docker.io"
}

delete_ghcr_version() {
	local error
	until error="$(gh api -X DELETE "/orgs/${IMAGE%%/*}/packages/container/${IMAGE#*/}/versions/$1" 2>&1 > /dev/null)"; do
		case "$error" in
			*"rate limit"*) sleep 60 ;;
			*downloads*)
				warn "ghcr.io and docker.io keep $2${3:+ ($3)}, it has more than 5,000 downloads on ghcr.io"
				return 1
				;;
			*) die "could not delete $2${3:+ ($3)} from ghcr.io: $error" ;;
		esac
	done
	sleep 1
}

delete_dockerhub_manifest() {
	local status
	while status="$(curl -sS --retry 3 -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $(registry_token docker.io pull,push,delete)" \
		"https://registry-1.docker.io/v2/$IMAGE/manifests/$1")" && [ "$status" = 429 ]; do
		sleep 60
	done
	echo "$status"
}

check_manifests() {
	local missing
	missing="$(head_manifests "$1" "$2" "$WORK_DIR/check-$1" | awk '$1 != 200 { print $2 }')"
	[ -z "$missing" ] || die "$(count <<< "$missing") manifests the kept tags point at are gone from $1, expected all of them: $(head -n 3 <<< "$missing" | paste -sd ' ' -)"
}

get_manifests() {
	local chunk token
	mkdir -p "$2"
	[ -s "$1" ] || return 0
	split -l 1000 "$1" "$WORK_DIR/chunk-"
	for chunk in "$WORK_DIR"/chunk-*; do
		token="$(registry_token ghcr.io pull)"
		xargs -P 16 -I {} curl -sSf --retry 3 -o "$2/{}" -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_TYPES" \
			"https://ghcr.io/v2/$IMAGE/manifests/{}" < "$chunk" || return 1
		rm "$chunk"
	done
}

head_manifests() {
	local chunk token
	mkdir -p "$3"
	[ -s "$2" ] || return 0
	split -l 1000 "$2" "$WORK_DIR/chunk-"
	for chunk in "$WORK_DIR"/chunk-*; do
		token="$(registry_token "$1" pull)"
		xargs -P 16 -I {} curl -sS --retry 3 --head -o "$3/{}" -w '%{http_code} {}\n' -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_TYPES" \
			"https://$(registry_host "$1")/v2/$IMAGE/manifests/{}" < "$chunk" || true
		rm "$chunk"
	done
}

tagged_digests() {
	awk -F '\t' -v digest="$2" -v tags="$3" 'FILENAME == ARGV[1] { keep[$1]; next }
		{ n = split($tags, list, ","); for (i = 1; i <= n; i++) if (list[i] in keep) { print $digest; next } }' "$WORK_DIR/kept-tags.txt" "$1" | sort -u
}

kept_closure() {
	awk 'FILENAME == ARGV[1] { root[$1]; print; next } $1 in root { print $2 }' "$WORK_DIR/$1.txt" "$WORK_DIR/children.txt" | sort -u
}

registry_token() {
	case "$1:$DOCKERHUB_USERNAME" in
		ghcr.io:*) curl -sSf --retry 3 "https://ghcr.io/token?scope=repository:$IMAGE:$2" ;;
		docker.io:) curl -sSf --retry 3 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$IMAGE:$2" ;;
		*) curl -sSf --retry 3 -u "$DOCKERHUB_USERNAME:$DOCKERHUB_TOKEN" "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$IMAGE:$2" ;;
	esac | jq -r .token
}

registry_host() {
	if [ "$1" = ghcr.io ]; then echo ghcr.io; else echo registry-1.docker.io; fi
}

header() {
	awk -v name="$1:" 'tolower($1) == name { print $2 }' "$2" | tr -d '\r'
}

rows() {
	awk -F '\t' -v from="$1" '$1 == from' "$WORK_DIR/rows.tsv"
}

human() {
	awk -v bytes="$1" 'BEGIN { split("B KB MB GB TB", unit, " "); i = 1; while (bytes >= 1000 && i < 5) { bytes /= 1000; i++ } printf "%.1f %s", bytes, unit[i] }'
}

limit() {
	if [ "$LIMIT" = 0 ]; then cat; else head -n "$LIMIT"; fi
}

count() {
	grep -c . || true
}

main
