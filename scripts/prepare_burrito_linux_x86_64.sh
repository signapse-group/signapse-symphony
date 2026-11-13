#!/usr/bin/env bash
set -euo pipefail

output=$1
otp_version=28.5.0.8
otp_sha256=af91a1ee88018280b1b45a9ff4bad749205d516dc8d2e8af8c7d63224a9fef76
loader_sha256=71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/gleam-community/erlang-linux-builds/releases/download/OTP-$otp_version/erlang-$otp_version-x64-musl.tar.gz" \
  --output "$scratch/otp.tar.gz"
printf '%s  %s\n' "$otp_sha256" "$scratch/otp.tar.gz" | sha256sum --check --status

root="otp_$otp_version"
mkdir "$scratch/$root"
tar -xzf "$scratch/otp.tar.gz" -C "$scratch/$root"
test "$(cat "$scratch/$root/releases/28/OTP_VERSION")" = "$otp_version"

# Point the upstream musl binaries at the same loader path Burrito embeds.
loader="/tmp/libc-musl-$loader_sha256.so"
find "$scratch/$root" -type f -perm -0100 -exec bash -ec '
  loader=$1
  shift
  for binary do
    if [[ $(patchelf --print-interpreter "$binary" 2>/dev/null) == /lib/ld-musl-x86_64.so.1 ]]; then
      patchelf --set-interpreter "$loader" "$binary"
    fi
  done
' bash "$loader" {} +
test "$(patchelf --print-interpreter "$scratch/$root/erts-16.4.0.7/bin/beam.smp")" = "$loader"
tar -C "$scratch" -czf "$output" "$root"
