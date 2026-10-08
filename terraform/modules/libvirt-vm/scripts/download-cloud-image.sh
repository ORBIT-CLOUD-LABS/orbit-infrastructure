#!/usr/bin/env bash
set -euo pipefail

image_url="$1"
expected_sha256="$2"
destination="$3"

mkdir -p "$(dirname "$destination")"
temporary_file="$(mktemp "${destination}.tmp.XXXXXX")"
trap 'rm -f "$temporary_file"' EXIT

curl --fail --location --retry 3 --output "$temporary_file" "$image_url"
printf '%s  %s\n' "$expected_sha256" "$temporary_file" | sha256sum --check --status
install -m 0644 "$temporary_file" "$destination"
