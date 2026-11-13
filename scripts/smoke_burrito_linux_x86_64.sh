#!/usr/bin/env bash
set -euo pipefail

artifact=$(realpath "$1")
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export SYMPHONY_INSTALL_DIR="$scratch/install"
cd "$scratch"

status=0
output=$(timeout 45 "$artifact" 2>&1) || status=$?
if [[ "$status" != 1 ]] || [[ "$output" != *'This Symphony implementation is a low key engineering preview.'* ]]; then
  printf '%s\n' "$output" >&2
  exit 1
fi

mapfile -t versions < <(find "$SYMPHONY_INSTALL_DIR" -type f -name OTP_VERSION)
test "${#versions[@]}" = 1
otp_version=$(cat "${versions[0]}")
test "$otp_version" = 28.5.0.8
beam="$(dirname "${versions[0]}")/erts-16.4.0.7/bin/beam.smp"
runtime=$("$beam" -V 2>&1)
[[ "$runtime" == *'version 16.4.0.7' ]]
printf '%s\n' "$otp_version"
