#!/usr/bin/env bash
set -euo pipefail

iso_path="$1"
user_data="$2"
meta_data="$3"
network_config="${4:-}"

if ! command -v cloud-localds >/dev/null 2>&1; then
  echo "cloud-localds is required. Install cloud-image-utils on the physical host." >&2
  exit 1
fi

mkdir -p "$(dirname "$iso_path")"
rm -f "$iso_path"

if [[ -n "$network_config" ]]; then
  cloud-localds --network-config="$network_config" "$iso_path" "$user_data" "$meta_data"
else
  cloud-localds "$iso_path" "$user_data" "$meta_data"
fi
