#!/usr/bin/env bash
# SPDX-FileCopyrightText: Nirapod toolchain contributors
# SPDX-License-Identifier: Apache-2.0
#
# scripts/toolchain.sh
# ====================
#
# Everything around a built toolchain: the host packages, packing it into
# the two release bundles, installing a release, checking an installed one,
# and running a command in its environment. build.sh builds it.
#
#   deps build             host packages build.sh needs, and the pinned opam
#   deps run               host libraries an installed toolchain needs, and
#                          the pinned opam (exec runs through it)
#   prepare                create $WORK, owned by the current user (sudo)
#   prune                  remove from the opam root what only an
#                          installation reads (download cache, sources, docs)
#   pack DIR               the two bundles of this platform into DIR:
#                          switch.tar.zst (the opam root) and
#                          compiler.tar.gz (the compiler, its build record,
#                          the Jasmin EasyCrypt library in the switch)
#   unpack FILE            unpack a bundle into $WORK
#   install RELEASE [PARTS]
#                          download the bundles of RELEASE for this platform
#                          from the GitHub release, check them against its
#                          SHA256SUMS, unpack, verify, and put this script
#                          in $WORK/bin as nirapod-toolchain; PARTS is
#                          "compiler switch" (default) or "compiler"
#   verify                 the binaries are those of the build record and
#                          run; with the switch present, jasmin-checksafety
#                          too (it loads the switch's abstract domains)
#   bin-path               put $WORK/bin on PATH (GitHub Actions) or print
#                          the export line
#   exec CMD...            run CMD in the switch, in the isolated
#                          environment build.sh gives its tools
#
# WORK is /opt/nirapod-toolchain unless set. The opam root records absolute
# paths, so a bundle works only where it was built: release bundles are
# built and installed there on every platform.
set -euo pipefail
umask 022

WORK=${WORK:-/opt/nirapod-toolchain}
SWITCH=${SWITCH:-nirapod-toolchain}
export OPAMROOT=${OPAMROOT:-$WORK/opam}
REPO=${TOOLCHAIN_REPO:-nirapod-labs/toolchain}

TOOLS=(jasminc jasmin-ct jasmin2ec jasmin-checksafety)
PRUNE_ROOT="download-cache"
PRUNE_SWITCH=".opam-switch/sources .opam-switch/build doc man"
SWITCH_PATHS=(opam logs/switch.txt logs/easycrypt-config.txt)
COMPILER_PATHS=(jasmin/compiler/jasminc jasmin/compiler/jasmin-ct
                jasmin/compiler/jasmin2ec jasmin/compiler/jasmin-checksafety
                jasmin/compiler/_build/install/default/bin
                jasmin/compiler/_build/default/entry
                state logs bin
                "opam/$SWITCH/lib/easycrypt/jasmin"
                "opam/$SWITCH/lib/easycrypt/config/jasmin.conf")

# opam, pinned by the SHA-256 of the release binary; build.sh requires this
# release.
OPAM_VERSION=2.6.0
OPAM_URL=https://github.com/ocaml/opam/releases/download/$OPAM_VERSION

APT_BUILD="build-essential git curl unzip m4 pkg-config bubblewrap zstd
           libgmp-dev libmpfr-dev libppl-dev libpcre2-dev zlib1g-dev"
APT_RUN="curl unzip zstd libgmp-dev libmpfr-dev libppl-dev libpcre2-dev zlib1g-dev"
BREW_BUILD="gmp mpfr ppl pcre2 pkgconf zstd"
BREW_RUN="gmp mpfr ppl pcre2 zstd"

die() { echo "toolchain.sh: $*" >&2; exit 1; }

platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  echo linux-x86_64 ;;
    Linux-aarch64) echo linux-aarch64 ;;
    Darwin-arm64)  echo macos-aarch64 ;;
    *) die "unsupported host $(uname -s)-$(uname -m)" ;;
  esac
}

sha256_check() {
  if command -v sha256sum > /dev/null; then sha256sum -c "$@"
  else shasum -a 256 -c "$@"; fi
}

sha256_of() {
  if command -v sha256sum > /dev/null; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

opam_asset() {
  case "$(platform)" in
    linux-x86_64)  echo "opam-$OPAM_VERSION-x86_64-linux a59184447f881005dae70b2ae455c3a7e9549834a41c635c49a5a28235eca758" ;;
    linux-aarch64) echo "opam-$OPAM_VERSION-arm64-linux aeaeb4294a9abaa7d37844d9138230125933c648e631da2eec888b5e4ce55bde" ;;
    macos-aarch64) echo "opam-$OPAM_VERSION-arm64-macos b57ed6cc082e560063989a285c59786b7c670087da2d317a87e4ba4c7973e71f" ;;
  esac
}

install_opam() {
  local asset sum dir
  read -r asset sum <<< "$(opam_asset)"
  dir=$(mktemp -d)
  curl -fsSL --retry 3 -o "$dir/$asset" "$OPAM_URL/$asset"
  (cd "$dir" && echo "$sum  $asset" | sha256_check -)
  sudo install -m 0755 "$dir/$asset" /usr/local/bin/opam
  rm -rf "$dir"
  opam --version
}

apt_install() {
  sudo apt-get update -q
  # shellcheck disable=SC2086
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $1
}

brew_install() {
  # shellcheck disable=SC2086
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet $1
}

cmd_deps() {
  case "${1:-}:$(platform)" in
    build:linux-*)
      apt_install "$APT_BUILD"
      # opam builds packages inside bubblewrap, which needs unprivileged
      # user namespaces; the runner image restricts them through AppArmor.
      # This relaxes a kernel hardening setting on a runner, a virtual
      # machine discarded after the job; never run `deps build` on a host
      # you keep.
      if [ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
        sudo sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0
      fi
      install_opam ;;
    build:macos-*) brew_install "$BREW_BUILD"; install_opam ;;
    run:linux-*)   apt_install "$APT_RUN"; install_opam ;;
    run:macos-*)   brew_install "$BREW_RUN"; install_opam ;;
    *) die "usage: toolchain.sh deps build|run" ;;
  esac
}

cmd_prepare() {
  if [ ! -d "$WORK" ]; then
    sudo mkdir -p "$WORK"
    sudo chown "$(id -u):$(id -g)" "$WORK"
  fi
  [ -w "$WORK" ] || die "$WORK is not writable"
}

cmd_prune() {
  local root prefix p
  root=$(opam var root)
  prefix=$(opam var prefix --switch="$SWITCH")
  [ -d "$prefix/.opam-switch" ] || die "$prefix is not an opam switch"
  for p in $PRUNE_ROOT; do rm -rf "${root:?}/$p"; done
  for p in $PRUNE_SWITCH; do rm -rf "${prefix:?}/$p"; done
  du -sh "$root"
}

# existing PATH...: the paths under $WORK that exist, NUL-separated.
existing() {
  local p
  for p in "$@"; do
    if [ -e "$WORK/$p" ]; then printf '%s\0' "$p"; fi
  done
}

cmd_pack() {
  local dir=${1:?usage: toolchain.sh pack DIR}
  mkdir -p "$dir"
  existing "${SWITCH_PATHS[@]}" | (cd "$WORK" && xargs -0 tar -cf -) \
    | zstd -q -T0 -3 -o "$dir/switch.tar.zst"
  existing "${COMPILER_PATHS[@]}" | (cd "$WORK" && xargs -0 tar -czf "$dir/compiler.tar.gz")
  ls -l "$dir"
}

cmd_unpack() {
  local file=${1:?usage: toolchain.sh unpack FILE}
  mkdir -p "$WORK"
  case "$file" in
    *.tar.zst) zstd -q -dc "$file" | tar -C "$WORK" -xf - ;;
    *.tar.gz)  tar -C "$WORK" -xzf "$file" ;;
    *) die "$file: expected a .tar.zst or .tar.gz archive" ;;
  esac
}

cmd_install() {
  local release=${1:?usage: toolchain.sh install RELEASE [PARTS]} parts=${2:-compiler switch}
  local plat dir url p f
  plat=$(platform)
  dir=$(mktemp -d)
  url="https://github.com/$REPO/releases/download/$release"
  curl -fsSL --retry 3 -o "$dir/SHA256SUMS" "$url/SHA256SUMS"
  for p in $parts; do
    case $p in
      compiler) f="toolchain-$release-$plat-compiler.tar.gz" ;;
      switch)   f="toolchain-$release-$plat-switch.tar.zst" ;;
      *) die "unknown part $p" ;;
    esac
    curl -fsSL --retry 3 -o "$dir/$f" "$url/$f"
    (cd "$dir" && grep " $f\$" SHA256SUMS | sha256_check -) || die "$f: checksum"
  done
  cmd_prepare
  for p in $parts; do
    case $p in
      switch)   cmd_unpack "$dir/toolchain-$release-$plat-switch.tar.zst" ;;
      compiler) cmd_unpack "$dir/toolchain-$release-$plat-compiler.tar.gz" ;;
    esac
  done
  rm -rf "$dir"
  # This script, as $WORK/bin/nirapod-toolchain, for `exec` and `verify`.
  install -m 0755 "$0" "$WORK/bin/nirapod-toolchain"
  cmd_verify
}

cmd_verify() {
  local b want got ran=()
  [ -f "$WORK/logs/binaries.sha256" ] || die "$WORK/logs/binaries.sha256: missing"
  for b in "${TOOLS[@]}"; do
    want=$(awk -v b="$b" '$2 == b { print $1 }' "$WORK/logs/binaries.sha256")
    [ -n "$want" ] || die "$b: not in the build record"
    got=$(sha256_of "$WORK/jasmin/compiler/$b" | cut -d' ' -f1)
    [ "$got" = "$want" ] || die "$b: SHA-256 $got, the build record says $want"
    if [ "$b" = jasmin-checksafety ] && [ ! -d "$OPAMROOT/$SWITCH" ]; then
      continue
    fi
    if [ "$b" = jasminc ]; then "$WORK/bin/$b" -version > /dev/null
    else "$WORK/bin/$b" --version > /dev/null; fi || die "$b does not run on this host"
    ran+=("$b")
  done
  echo "verify: ${TOOLS[*]} are those of the build record; ${ran[*]} run"
}

cmd_bin_path() {
  [ -d "$WORK/bin" ] || die "$WORK/bin: missing; build or install the toolchain first"
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$WORK/bin" >> "$GITHUB_PATH"
  else
    echo "export PATH=\"$WORK/bin:\$PATH\""
  fi
}

# The environment of build.sh: its opam root and no other OPAM* setting,
# and home, configuration, data, cache and temporary directories under
# $WORK, so that EasyCrypt and Why3 read only the switch's configuration,
# as they did when the build checked it.
cmd_exec() {
  [ $# -ge 1 ] || die "usage: toolchain.sh exec CMD..."
  local v
  for v in $(env | sed -n 's/^\(OPAM[A-Z_]*\)=.*/\1/p'); do
    [ "$v" = OPAMROOT ] || unset "$v"
  done
  mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/xdg/config" "$WORK/xdg/data" \
           "$WORK/xdg/cache" "$WORK/xdg/etc" "$WORK/xdg/share"
  HOME="$WORK/home" TMPDIR="$WORK/tmp" \
  XDG_CONFIG_HOME="$WORK/xdg/config" XDG_DATA_HOME="$WORK/xdg/data" \
  XDG_CACHE_HOME="$WORK/xdg/cache" XDG_CONFIG_DIRS="$WORK/xdg/etc" \
  XDG_DATA_DIRS="$WORK/xdg/share" \
    opam exec --switch="$SWITCH" -- "$@"
}

case "${1:-}" in
  deps)     shift; cmd_deps "$@" ;;
  prepare)  shift; cmd_prepare ;;
  prune)    shift; cmd_prune ;;
  pack)     shift; cmd_pack "$@" ;;
  unpack)   shift; cmd_unpack "$@" ;;
  install)  shift; cmd_install "$@" ;;
  verify)   shift; cmd_verify ;;
  bin-path) shift; cmd_bin_path ;;
  exec)     shift; cmd_exec "$@" ;;
  platform) platform ;;
  *) echo "usage: toolchain.sh deps|prepare|prune|pack|unpack|install|verify|bin-path|exec|platform ..." >&2
     exit 2 ;;
esac
