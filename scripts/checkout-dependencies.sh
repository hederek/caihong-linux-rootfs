#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=config/dependencies.env
. "$project_dir/config/dependencies.env"
dependency_scope=${DEPENDENCY_SCOPE:-release}

case "$dependency_scope" in
	release|kernel) ;;
	*)
		echo "DEPENDENCY_SCOPE must be release or kernel" >&2
		exit 2
		;;
esac

checkout()
{
	name=$1
	ref=$2
	target=$3
	repository=$4
	if [ -d "$target/.git" ]; then
		if [ -n "$(git -C "$target" status --porcelain --untracked-files=no)" ]; then
			echo "refusing a dependency with uncommitted changes: $target" >&2
			exit 1
		fi
		git -C "$target" remote set-url origin "$repository"
	else
		rm -rf -- "$target"
		mkdir -p "$(dirname -- "$target")"
		git init -q "$target"
		git -C "$target" remote add origin "$repository"
	fi
	attempt=1
	while ! git -C "$target" fetch --depth=1 origin "$ref"; do
		if [ "$attempt" -ge 4 ]; then
			echo "failed to fetch $name after $attempt attempts" >&2
			exit 1
		fi
		echo "retrying $name fetch ($attempt/4)" >&2
		sleep $((attempt * 2))
		attempt=$((attempt + 1))
	done
	git -C "$target" checkout -q --detach FETCH_HEAD
	actual=$(git -C "$target" rev-parse HEAD)
	{
		printf '%s_REPOSITORY=%s\n' "$name" "$repository"
		printf '%s_REF=%s\n' "$name" "$ref"
		printf '%s_COMMIT=%s\n' "$name" "$actual"
	} >> "$resolved"
}

fetch_linux_tarball()
{
	target=$1
	commit=$2
	repo_path=${LINUX_REPOSITORY#https://github.com/}
	repo_path=${repo_path%.git}
	tarball=$(mktemp)
	downloaded=0

	# Local builds can point LINUX_TARBALL at an already downloaded archive.
	if [ -n "${LINUX_TARBALL:-}" ] && [ -f "$LINUX_TARBALL" ]; then
		cp -- "$LINUX_TARBALL" "$tarball"
		downloaded=1
	fi
	# Use the authenticated API first on CI to stay clear of codeload's
	# unauthenticated rate limit; fall back to the plain codeload archive.
	if [ "$downloaded" -eq 0 ] && [ -n "${GITHUB_TOKEN:-}" ]; then
		if curl -fsSL --retry 3 --retry-delay 5 \
			-H "Authorization: Bearer $GITHUB_TOKEN" \
			-o "$tarball" \
			"https://api.github.com/repos/$repo_path/tarball/$commit"; then
			downloaded=1
		fi
	fi
	if [ "$downloaded" -eq 0 ]; then
		if ! curl -fsSL --retry 5 --retry-delay 5 -o "$tarball" \
			"https://codeload.github.com/$repo_path/tar.gz/$commit"; then
			rm -f -- "$tarball"
			echo "failed to download kernel $commit" >&2
			exit 1
		fi
	fi
	rm -rf -- "$target"
	mkdir -p -- "$target"
	tar xzf "$tarball" --strip-components=1 -C "$target"
	rm -f -- "$tarball"
	{
		printf 'LINUX_REPOSITORY=%s\n' "$LINUX_REPOSITORY"
		printf 'LINUX_REF=%s\n' "$commit"
		printf 'LINUX_COMMIT=%s\n' "$commit"
	} >> "$resolved"
}

mkdir -p "$project_dir/build"
resolved="$project_dir/build/dependencies.resolved.env"
: > "$resolved"
if [ -n "${LINUX_COMMIT:-}" ]; then
	fetch_linux_tarball "$project_dir/linux" "$LINUX_COMMIT"
else
	checkout LINUX "$LINUX_REF" "$project_dir/linux" "$LINUX_REPOSITORY"
fi
if [ "$dependency_scope" = release ]; then
	checkout LIBCAMERA "$LIBCAMERA_REF" \
		"$project_dir/external/libcamera" "$LIBCAMERA_REPOSITORY"
	checkout PLASMA_CAMERA "$PLASMA_CAMERA_REF" \
		"$project_dir/external/plasma-camera" "$PLASMA_CAMERA_REPOSITORY"
	checkout QBOOTCTL "$QBOOTCTL_REF" \
		"$project_dir/external/qbootctl" "$QBOOTCTL_REPOSITORY"
fi
checkout MKBOOTIMG "$MKBOOTIMG_REF" \
	"$project_dir/external/mkbootimg" "$MKBOOTIMG_REPOSITORY"
echo "checked out Caihong $dependency_scope dependencies"
cat "$resolved"
