#!/usr/bin/env bash
# SPDX-FileCopyrightText: Nirapod toolchain contributors
# SPDX-License-Identifier: Apache-2.0
#
# build.sh
# ========
#
# Builds the toolchain from the pins in this repository.
#
#   ./build.sh [--no-easycrypt] [switch|jasmin|test|all]
#
#   switch   opam switch: OCaml, the Rocq libraries of the Jasmin proofs, the
#            OCaml libraries of the compiler, EasyCrypt, Why3, the provers
#   jasmin   the pinned commit of the Jasmin fork, built as upstream builds
#            it: Rocq proofs, extraction, OCaml build
#   test     the compiler's own test suites and the Jasmin EasyCrypt
#            library, on the built tree
#   all      switch, jasmin, test (the default)
#
# --no-easycrypt leaves out EasyCrypt, Why3 and the SMT provers: the switch
# holds only what the compiler needs, and the test step does not check the
# Jasmin EasyCrypt library. Everything else runs as in a full build. It is
# the build for platforms without pinned prover binaries (Linux on AArch64);
# on such a platform the build stops unless the option is given.
#
# Inputs: jasmin/PIN, easycrypt/PIN, opam-packages.txt, and the lists jasmin/ASSUMPTIONS, jasmin/ADMITS and
# jasmin/ECLIB_AXIOMS. The build needs network access for the pinned
# repositories, the package archives they list, and the prover binaries;
# each is checked against its pin.
#
# What each step establishes
# --------------------------
#
# switch  The switch sees exactly two opam repositories, each a checkout of a
#         pinned commit; opam checks every package archive against the
#         checksum in those repositories. coqword and EasyCrypt are pinned by
#         commit, the provers by the SHA-256 of their release files. The
#         installed package set must equal opam-packages.txt; the jasmin and
#         test steps check it again before they use the switch.
#
# jasmin  `make -C proofs all` machine-checks the whole Rocq development of
#         the pinned commit, including the compiler correctness theorem and
#         any proof our commits on the fork change or add. The
#         extracted OCaml is removed and extracted again from the proofs
#         (`make -C compiler CIL`), hashed, and the compiler is built from
#         it; the hashes must be unchanged after the build. The assumptions
#         of the end-to-end theorem and of the ARMv8-A and x86-64
#         architecture records must be exactly those of jasmin/ASSUMPTIONS.
#         The declarations that can add an assumption or leave a proof
#         unfinished must be exactly those of jasmin/ADMITS (Rocq) and
#         jasmin/ECLIB_AXIOMS (Jasmin EasyCrypt library). Hand-written OCaml
#         (front end, printers, safety and constant-time checkers) is
#         outside the proofs.
#
# test    The compiler's dune test suites (printing, negative, safety and
#         speculative constant-time tests, cram tests), all built and run
#         again in an emptied build directory with dune's cache disabled, and
#         the check of eclib/ with the pinned EasyCrypt and provers (run a
#         second time, with one job, if the first run fails).
#
# Outputs, under $WORK (default ./work; never committed):
#
#   opam/      the opam root, unless OPAMROOT is set
#   bin/       jasminc, jasmin-ct, jasmin2ec, jasmin-checksafety
#   jasmin/    the Jasmin tree (the pinned commit) and its build products
#   logs/      switch.txt, provenance.txt, assumptions.log, admit-scan.log,
#              eclib-axioms.log, cil.sha256, binaries.sha256,
#              test-suites.txt, and the log of every step
#   home/, xdg/, tmp/
#              the home, configuration, data, cache and temporary
#              directories the tools see
#
# Environment:
#
#   SWITCH    opam switch (default nirapod-toolchain); never made the default
#   WORK      work directory (default ./work); one build at a time. The
#             release bundles are built with WORK=/opt/nirapod-toolchain,
#             because the opam root records absolute paths
#   JOBS      parallel jobs (default 4); every heavy step runs under nice
#   OPAMROOT  opam root (default $WORK/opam); a missing root is initialised.
#             Other OPAM* variables of the caller are ignored.
#
# HOME, the XDG_* directories and TMPDIR point into $WORK, so no tool reads
# a configuration of the user's own; the switch step checks that every
# configuration file EasyCrypt reports, and Why3's, is the switch's.
#
# Platforms: macOS on AArch64, Linux on x86-64, and Linux on AArch64 with
# --no-easycrypt.
#
# Every step stops on the first error. The build refuses modified inputs:
# this repository must match its checked-out commit, and the Jasmin tree
# must be exactly the pinned commit.

# shellcheck source-path=SCRIPTDIR
set -euo pipefail
umask 022

usage() {
  echo "usage: ./build.sh [--no-easycrypt] [switch|jasmin|test|all]"
}

EASYCRYPT=1
STEP=
for arg in "$@"; do
  case $arg in
    --no-easycrypt) EASYCRYPT=0 ;;
    -h|--help) usage; exit 0 ;;
    switch|jasmin|test|all)
      [ -z "$STEP" ] || { usage >&2; exit 2; }
      STEP=$arg ;;
    *) usage >&2; exit 2 ;;
  esac
done
STEP=${STEP:-all}

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=./jasmin/PIN
. "$HERE/jasmin/PIN"
# shellcheck source=./easycrypt/PIN
. "$HERE/easycrypt/PIN"

SWITCH=${SWITCH:-nirapod-toolchain}
WORK=${WORK:-$HERE/work}
JOBS=${JOBS:-4}
NICE="nice -n 15"
PLATFORM="$(uname -s)-$(uname -m)"
TREE="$WORK/jasmin"
LOG="$WORK/logs"

case "$PLATFORM" in
  Darwin-arm64) OS=macos ;;
  Linux-x86_64|Linux-aarch64) OS=linux ;;
  *) echo "build.sh: unsupported platform $PLATFORM" >&2; exit 2 ;;
esac
if [ "$EASYCRYPT" = 1 ] && ! prover_assets "$PLATFORM" >/dev/null; then
  echo "build.sh: no pinned SMT prover binaries for $PLATFORM;" \
       "build the compiler alone with --no-easycrypt" >&2
  exit 2
fi
if [ "$EASYCRYPT" = 1 ]; then
  COMPONENTS="Jasmin, EasyCrypt, Why3 and the SMT provers"
else
  COMPONENTS="Jasmin only (--no-easycrypt: no EasyCrypt, Why3 or SMT provers)"
fi

say() { printf '== %s (%s)\n' "$*" "$(date -u +%FT%TZ)"; }
die() { echo "build.sh: $*" >&2; exit 1; }

# One build per work directory. A lock left by a killed build is reported,
# not taken over.
mkdir -p "$WORK"
mkdir "$WORK/lock" 2>/dev/null \
  || die "$WORK is in use by another build (remove $WORK/lock if none runs)"
trap 'rmdir "$WORK/lock"' EXIT
mkdir -p "$WORK/src" "$WORK/dl" "$WORK/state" "$LOG" \
         "$WORK/home" "$WORK/tmp" "$WORK/xdg/config" "$WORK/xdg/data" \
         "$WORK/xdg/cache" "$WORK/xdg/etc" "$WORK/xdg/share"

# Only the opam root of this build is used: the caller's OPAM* settings and
# the switches of other roots on PATH are dropped.
for v in $(env | sed -n 's/^\(OPAM[A-Z_]*\)=.*/\1/p'); do
  [ "$v" = OPAMROOT ] || unset "$v"
done
export OPAMROOT=${OPAMROOT:-$WORK/opam}
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/\.opam/' | paste -sd: -)
export PATH
export HOME="$WORK/home" TMPDIR="$WORK/tmp" \
       XDG_CONFIG_HOME="$WORK/xdg/config" XDG_DATA_HOME="$WORK/xdg/data" \
       XDG_CACHE_HOME="$WORK/xdg/cache" XDG_CONFIG_DIRS="$WORK/xdg/etc" \
       XDG_DATA_DIRS="$WORK/xdg/share"

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$@"
  else shasum -a 256 "$@"; fi
}

# Comment-free lines of an input file.
entries() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# fetch_commit URL COMMIT DIR: DIR is a clean checkout of exactly COMMIT.
fetch_commit() {
  local url=$1 commit=$2 dir=$3 head
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
  head=$(git -C "$dir" rev-parse HEAD)
  [ "$head" = "$commit" ] || die "$dir: HEAD $head, expected $commit"
  [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir: working tree is not clean"
}

# A build names the project commit it was built from, so its inputs must be
# committed. Outside a git checkout this cannot be checked; provenance.txt
# then says so.
check_inputs() {
  if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
    [ -z "$(git -C "$HERE" status --porcelain -- .)" ] \
      || die "uncommitted changes in this repository; commit them first"
  fi
}

# Tools and libraries the build needs from the host;
# PPL is checked by opam's conf-ppl.
preflight() {
  local t tools=(git curl make m4 pkg-config cc c++ opam) libs=(gmp mpfr)
  if [ "$EASYCRYPT" = 1 ]; then
    tools+=(unzip)
    libs+=(libpcre2-8 zlib)
  fi
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null || die "missing host tool: $t"
  done
  pkg-config --exists "${libs[@]}" \
    || die "pkg-config does not find ${libs[*]}"
  [ "$(opam --version)" = "$OPAM_VERSION" ] \
    || die "opam $(opam --version), expected $OPAM_VERSION"
}

# Compare a sorted list with the comment-free entries of an input file.
expect_list() {
  local got=$1 file=$2 what=$3 want
  want=$(entries "$file" | LC_ALL=C sort)
  if [ "$got" != "$want" ]; then
    diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2 || true
    die "$what differs from ${file#"$HERE"/} (< listed, > found)"
  fi
}

# ---------------------------------------------------------------------------
# switch

switch_repositories() {
  fetch_commit "$OPAM_REPO_URL" "$OPAM_REPO_COMMIT" "$WORK/src/opam-repository"
  fetch_commit "$ROCQ_OPAM_URL" "$ROCQ_OPAM_COMMIT" "$WORK/src/rocq-opam"
  REPO_OCAML="nirapod-opam-${OPAM_REPO_COMMIT:0:12}"
  REPO_ROCQ="nirapod-rocq-${ROCQ_OPAM_COMMIT:0:12}"
  if [ ! -f "$OPAMROOT/config" ]; then
    opam init --bare --no-setup -y "$REPO_OCAML" "$WORK/src/opam-repository"
  fi
  # The listings are read in full before they are searched: with pipefail,
  # `opam ... | grep -q` fails whenever grep exits before opam has written
  # everything.
  local repos
  repos=$(opam repository list --all --short)
  grep -Fqx "$REPO_OCAML" <<< "$repos" \
    || opam repository add --dont-select "$REPO_OCAML" "$WORK/src/opam-repository"
  grep -Fqx "$REPO_ROCQ" <<< "$repos" \
    || opam repository add --dont-select "$REPO_ROCQ" "$WORK/src/rocq-opam/released"
}

# Each prover is installed as <name>-<version>, the form under which Why3
# detects several versions of one prover side by side. Any other copy of a
# prover in the switch is removed first, and Why3 searches only the
# switch's bin directory (switch_easycrypt_config), so a prover installed
# elsewhere on the host is not used.
switch_provers() {
  local bin name version url sum member file got tmp
  bin=$(opam var bin)
  rm -f "$bin"/z3 "$bin"/z3-* "$bin"/cvc5 "$bin"/cvc5-* "$bin"/alt-ergo "$bin"/alt-ergo-*
  prover_assets "$PLATFORM" | while read -r name version url sum member; do
    file="$WORK/dl/$name-$version-$(basename "$url")"
    if [ ! -f "$file" ]; then
      curl -fsSL -o "$file.part" "$url"
      mv "$file.part" "$file"
    fi
    got=$(sha256_of "$file" | cut -d' ' -f1)
    [ "$got" = "$sum" ] || die "$file: SHA-256 $got, expected $sum"
    if [ "$member" = - ]; then
      install -m 0755 "$file" "$bin/$name-$version"
    else
      tmp=$(mktemp -d "$WORK/tmp/prover.XXXXXX")
      unzip -q -o "$file" "$member" -d "$tmp"
      install -m 0755 "$tmp/$member" "$bin/$name-$version"
      rm -rf "$tmp"
    fi
    "$bin/$name-$version" --version >/dev/null 2>&1 \
      || die "$name-$version does not run on this host"
  done
}

# EasyCrypt reads every *.conf of its system configuration directory. This
# one points it at a Why3 configuration that belongs to the switch. The key
# is `why3conf` (EasyCrypt src/ecOptions.ml, read_ini_file). The user's own
# configuration is out of reach because XDG_CONFIG_HOME is under $WORK.
# Why3 looks for provers on PATH, which is limited here to the switch's bin
# directory: a distribution z3 elsewhere on PATH would otherwise be added
# next to the pinned binaries.
switch_easycrypt_config() {
  local lib bin
  lib=$(opam var lib)/easycrypt
  bin=$(opam var bin)
  mkdir -p "$lib/config"
  printf '[general]\nwhy3conf = %s\n' "$lib/why3.conf" > "$lib/config/toolchain.conf"
  PATH="$bin" "$bin/easycrypt" why3config -why3 "$lib/why3.conf"
  easycrypt config > "$LOG/easycrypt-config.txt" 2>&1
  grep -Fqx "  $lib/why3.conf" "$LOG/easycrypt-config.txt" \
    || die "EasyCrypt does not use $lib/why3.conf"
  # Every path listed under a configuration heading must be the switch's.
  awk '/configuration (file|directory)/ { on = 1; next }
       /^[^ ]/ { on = 0 }
       on && /^  / { print substr($0, 3) }' "$LOG/easycrypt-config.txt" \
    > "$WORK/tmp/easycrypt-config-paths"
  [ -s "$WORK/tmp/easycrypt-config-paths" ] \
    || die "EasyCrypt reports no configuration file"
  ! awk -v lib="$lib/" 'index($0, lib) != 1' "$WORK/tmp/easycrypt-config-paths" \
    | grep . || die "EasyCrypt reads configuration outside $lib (listed above)"
  switch_check_provers "$lib/why3.conf" "$bin"
}

# switch_check_provers WHY3CONF BIN: EasyCrypt resolves a name such as
# Z3@4.12 to the lowest known version at least the one named, so the
# provers it knows must be exactly those of prover_assets, by name and
# version; a binary whose version Why3 cannot read shows as 0.0.0 and
# fails the comparison. Variants such as Z3[noBV] are configurations of the
# same binary and are not compared. Every binary in the Why3 configuration
# must also be the switch's: a second binary reporting a pinned version
# would appear only as a variant.
switch_check_provers() {
  local conf=$1 bin=$2 want got
  want=$(prover_assets "$PLATFORM" | while read -r name version _; do
           case $name in
             (z3) echo "Z3@$version" ;;
             (cvc5) echo "CVC5@$version" ;;
             (alt-ergo) echo "Alt-Ergo@$version" ;;
             (*) die "no Why3 name for prover $name" ;;
           esac
         done | LC_ALL=C sort)
  got=$(sed -n 's/^known provers: //p' "$LOG/easycrypt-config.txt" | tr ',' '\n' \
        | sed 's/^ *//' | { grep -v '\[' || true; } | LC_ALL=C sort)
  if [ "$got" != "$want" ]; then
    diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2 || true
    die "the provers EasyCrypt knows differ from the pinned set" \
        "(< pinned, > known)" \
        "(see $LOG/easycrypt-config.txt)"
  fi
  ! sed -n 's/^path = "\(.*\)"$/\1/p' "$conf" | awk -v bin="$bin/" 'index($0, bin) != 1' \
    | grep . || die "$conf names prover binaries outside $bin (listed above)"
  echo "provers: exactly the pinned set"
}

# The installed packages must be exactly those of opam-packages.txt (name,
# version, the operating system a line is restricted to, if any, and
# whether EasyCrypt is built).
switch_check_packages() {
  local expected installed
  expected=$(entries "$HERE/opam-packages.txt" | awk -v os="$OS" -v ec="$EASYCRYPT" '
    { keep = 1
      for (i = 3; i <= NF; i++) {
        if (($i == "linux" || $i == "macos") && $i != os) keep = 0
        if ($i == "easycrypt" && ec != 1) keep = 0
      }
      if (keep) print $1, $2 }' | LC_ALL=C sort)
  installed=$(opam list --installed --columns=name,version -s \
    | awk '{print $1, $2}' | LC_ALL=C sort)
  if [ "$expected" != "$installed" ]; then
    diff <(echo "$expected") <(echo "$installed") | sed 's/^/  /' >&2 || true
    die "switch $SWITCH does not hold exactly the packages of" \
        "opam-packages.txt (< expected, > installed)"
  fi
}

# Before the jasmin and test steps use the switch: the host, the switch and
# its package set are those the switch step checked.
use_switch() {
  preflight
  grep -Fqx "$SWITCH" <<< "$(opam switch list --short)" \
    || die "no switch $SWITCH in $OPAMROOT; run the switch step"
  export OPAMSWITCH=$SWITCH
  switch_check_packages
  eval "$(opam env)"
}

step_switch() {
  say "switch $SWITCH"
  check_inputs
  preflight
  switch_repositories
  if ! grep -Fqx "$SWITCH" <<< "$(opam switch list --short)"; then
    $NICE opam switch create "$SWITCH" "ocaml-base-compiler.$OCAML_VERSION" \
      --repositories="$REPO_OCAML,$REPO_ROCQ" --no-switch -y -j"$JOBS"
  fi
  export OPAMSWITCH=$SWITCH OPAMYES=1 OPAMJOBS=$JOBS
  [ "$(opam repository list --short | tr '\n' ' ')" = "$REPO_OCAML $REPO_ROCQ " ] \
    || die "switch $SWITCH does not use exactly the pinned repositories"
  opam pin add -n --no-depexts coq-mathcomp-word "git+$COQWORD_URL#$COQWORD_COMMIT"
  if [ "$EASYCRYPT" = 1 ]; then
    opam pin add -n --no-depexts easycrypt "git+$EASYCRYPT_URL#$EASYCRYPT_COMMIT"
    # shellcheck disable=SC2086
    $NICE opam install --no-depexts $JASMIN_OPAM_PACKAGES $EASYCRYPT_OPAM_PACKAGES \
      coq-mathcomp-word easycrypt
  else
    # shellcheck disable=SC2086
    $NICE opam install --no-depexts $JASMIN_OPAM_PACKAGES coq-mathcomp-word
  fi
  switch_check_packages
  eval "$(opam env)"
  if [ "$EASYCRYPT" = 1 ]; then
    switch_provers
    switch_easycrypt_config
  fi
  {
    echo "date: $(date -u +%FT%TZ)"
    echo "platform: $PLATFORM ($(uname -sr))"
    echo "components: $COMPONENTS"
    echo "C compiler: $(cc --version 2>&1 | head -1)"
    echo "opam: $(opam --version)"
    echo "opam root: $OPAMROOT"
    echo "switch: $SWITCH"
    echo "repositories:"; opam repository list
    echo "pins:"; opam pin list
    echo "packages:"; opam list --columns=name,version -s
    if [ "$EASYCRYPT" = 1 ]; then
      echo "provers:"
      prover_assets "$PLATFORM" | while read -r name version _; do
        echo "  $name-$version: $("$name-$version" --version 2>&1 | head -1)"
      done
      echo "easycrypt config:"; cat "$LOG/easycrypt-config.txt"
    fi
  } > "$LOG/switch.txt"
  cat "$LOG/switch.txt"
}

# ---------------------------------------------------------------------------
# jasmin

# The tree is the pinned commit of the fork, fetched with its history so
# that the commits on the upstream base can be checked and listed. It is
# rebuilt from scratch whenever the commit, the switch or the packages
# installed in it change (compiled Rocq libraries are only valid with the
# libraries they were compiled against); otherwise its build products are
# reused by the incremental make.
jasmin_tree() {
  local id src="$WORK/src/jasmin"
  [ -d "$src/.git" ] || git init -q "$src"
  git -C "$src" cat-file -e "$JASMIN_COMMIT^{commit}" 2>/dev/null \
    || git -C "$src" fetch -q "$JASMIN_URL" "$JASMIN_COMMIT"
  git -C "$src" merge-base --is-ancestor "$JASMIN_BASE" "$JASMIN_COMMIT" \
    || die "jasmin/PIN: JASMIN_BASE is not an ancestor of JASMIN_COMMIT"
  id=$({ echo "$JASMIN_COMMIT"
         echo "$OPAMROOT/$SWITCH"
         opam list --installed --columns=name,version -s; } \
       | sha256_of - | cut -d' ' -f1)
  if [ ! -d "$TREE" ] || [ "$(cat "$WORK/state/tree" 2>/dev/null)" != "$id" ]; then
    rm -rf "$TREE"
    git -C "$src" worktree prune
    git -C "$src" worktree add -q --detach "$TREE" "$JASMIN_COMMIT"
    echo "$id" > "$WORK/state/tree"
  fi
  jasmin_tree_check
}

# The tree is the pinned commit, with no modified file and no file that is
# neither tracked nor ignored (dune would build any source file it finds).
# The test step's own build directory is the one exception.
tree_status() {
  git -C "$TREE" status --porcelain -- . ':!compiler/_build-test'
}

jasmin_tree_check() {
  [ "$(git -C "$TREE" rev-parse HEAD)" = "$JASMIN_COMMIT" ] \
    || die "$TREE: HEAD is not $JASMIN_COMMIT"
  [ -z "$(tree_status)" ] || die "$TREE: modified or untracked files"
}

jasmin_provenance() {
  local proofs
  if [ -e "$TREE/proofs/compiler/it_compiler_proof.vo" ]; then
    proofs="incremental (existing build products)"
  else
    proofs="from scratch"
  fi
  {
    echo "date: $(date -u +%FT%TZ)"
    echo "platform: $PLATFORM ($(uname -sr))"
    echo "components: $COMPONENTS"
    if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
      echo "project commit: $(git -C "$HERE" rev-parse HEAD)"
    else
      echo "project commit: none (not a git checkout; inputs not checked)"
    fi
    echo "jasmin commit: $JASMIN_COMMIT ($JASMIN_URL, $JASMIN_TAG)"
    echo "jasmin tree: $(git -C "$TREE" rev-parse 'HEAD^{tree}')"
    echo "upstream base: $JASMIN_BASE"
    echo "integration (first parent):"
    git -C "$TREE" log --reverse --first-parent --format='  %H %s' "$JASMIN_BASE..HEAD"
    echo "commits on the base:"
    git -C "$TREE" log --reverse --no-merges --format='  %H %an: %s' "$JASMIN_BASE..HEAD"
    echo "proof build: $proofs"
    echo "switch: $SWITCH (opam root $OPAMROOT)"
    echo "C compiler: $(cc --version 2>&1 | head -1)"
    echo "opam: $(opam --version)"
    echo "ocaml: $(ocamlfind ocamlopt -version)"
    echo "rocq: $(rocq -v 2>/dev/null | head -1)"
    echo "dune: $(dune --version)"
    echo "opam packages:"
    opam list --columns=name,version -s | sed 's/^/  /'
    echo "opam pins:"
    opam pin list | sed 's/^/  /'
  } > "$LOG/provenance.txt"
  cat "$LOG/provenance.txt"
}

# The extracted OCaml, as hashes of its files.
#
# This record and the two scans below are compared byte for byte across
# hosts, so each is sorted with LC_ALL=C: the shell's glob order follows
# its locale, and grep -r lists files in the file system's directory order.
cil_hashes() {
  (cd "$TREE/compiler/src/CIL" && sha256_of ./*.ml ./*.mli) | LC_ALL=C sort -k2
}

# Print Assumptions of the end-to-end compiler theorem and of the two
# architecture records this project compiles for. Each query must have its
# own report, and the names it prints must be exactly those listed for it
# in jasmin/ASSUMPTIONS.
jasmin_assumptions() {
  local dir rflags q n got want
  local queries="it_compile_prog_to_asmP armv8a_h_params x86_h_params"
  local modules="it_compiler_proof armv8a_params_proof x86_params_proof"
  dir=$(mktemp -d "$WORK/tmp/assumptions.XXXXXX")
  {
    echo "From Jasmin Require Import $modules."
    for q in $queries; do echo "Print Assumptions $q."; done
  } > "$dir/Assumptions.v"
  rflags=$(grep -E '^-R ' "$TREE/proofs/_CoqProject" \
             | sed "s#^-R \([^ ]*\) #-R $TREE/proofs/\1 #" | tr '\n' ' ')
  # shellcheck disable=SC2086
  (cd "$dir" && $NICE rocq compile $rflags Assumptions.v) > "$LOG/assumptions.log" 2>&1 \
    || { tail -30 "$LOG/assumptions.log"
         die "Print Assumptions failed, see $LOG/assumptions.log"; }
  rm -rf "$dir"
  cat "$LOG/assumptions.log"
  # One report per query, in order: "Axioms:" followed by one name per line
  # at column 0 (its type on the following, indented lines), or "Closed
  # under the global context".
  n=$(grep -cE '^(Axioms:|Closed under the global context)' "$LOG/assumptions.log")
  [ "$n" = "$(echo "$queries" | wc -w | tr -d ' ')" ] \
    || die "expected one assumption report per query in $LOG/assumptions.log"
  for q in $queries; do
    got=$(awk -v q="$q" -v qs="$queries" '
      BEGIN { split(qs, a, " ") }
      /^(Axioms:|Closed under the global context)/ { block++; next }
      a[block] == q && /^[A-Za-z_][A-Za-z0-9_.'"'"']* :/ { print $1 }
    ' "$LOG/assumptions.log" | LC_ALL=C sort)
    want=$(awk -v q="[$q]" '
      /^\[/ { cur = $0; next }
      cur == q { sub(/#.*/, ""); if (NF) print $1 }
    ' "$HERE/jasmin/ASSUMPTIONS" | LC_ALL=C sort)
    if [ "$got" != "$want" ]; then
      diff <(echo "$want") <(echo "$got") | sed 's/^/  /' >&2 || true
      die "assumptions of $q differ from jasmin/ASSUMPTIONS (< listed, > printed)"
    fi
  done
  echo "assumptions: as listed in jasmin/ASSUMPTIONS"
}

# Every Rocq declaration that can leave a proof unfinished or add an
# assumption, as `file: Keyword name`; it must equal jasmin/ADMITS. Section
# variables (Variable, Context) are parameters of the section and are not
# listed. The Print Assumptions report above is the authority on what a
# theorem rests on; this scan makes any new such declaration a reviewed
# change.
jasmin_admit_scan() {
  local got unfinished declared
  unfinished='(^|[^A-Za-z_])(Admitted|admit|Abort)\.'
  declared='^[[:space:]]*((Local|Global)[[:space:]]+)?'
  declared+='(Axiom|Axioms|Parameter|Parameters|Hypothesis|Hypotheses|Conjecture)'
  declared+='[[:space:]]'
  (cd "$TREE" && { LC_ALL=C grep -a -rnE "$unfinished|$declared" --include='*.v' proofs || true; }) \
    | LC_ALL=C sort -t: -k1,1 -k2,2n > "$LOG/admit-scan.log"
  got=$(sed -E 's/^([^:]+):[0-9]+:[[:space:]]*(.*)$/\1: \2/' "$LOG/admit-scan.log" \
        | awk '{ s = $1 " " $2; if (NF >= 3) s = s " " $3; print s }' | LC_ALL=C sort)
  echo "Rocq declarations found: $(wc -l < "$LOG/admit-scan.log" | tr -d ' ')"
  expect_list "$got" "$HERE/jasmin/ADMITS" "the Rocq admit scan"
  echo "admit scan: as listed in jasmin/ADMITS"
}

# Every axiom and admission of the Jasmin EasyCrypt library, as `file:
# axiom name`, with `<-` for a line that realises an axiom of a cloned
# theory; it must equal jasmin/ECLIB_AXIOMS.
jasmin_eclib_scan() {
  local got axiom admitted
  axiom='^[[:space:]]*(declare[[:space:]]+)?axiom[[:space:]]'
  admitted='(^|[^A-Za-z_])(admit|admitted)([^A-Za-z_]|$)'
  (cd "$TREE" && { LC_ALL=C grep -a -rnE "$axiom|$admitted" --include='*.ec' eclib || true; }) \
    | LC_ALL=C sort -t: -k1,1 -k2,2n > "$LOG/eclib-axioms.log"
  got=$(sed -E 's/^([^:]+):[0-9]+:[[:space:]]*(.*)$/\1: \2/' "$LOG/eclib-axioms.log" \
        | awk '{ kw = $2; name = $3
                 if (kw == "declare") { kw = $3; name = $4 }
                 sub(/[^A-Za-z0-9_'"'"'].*$/, "", name)
                 r = ($0 ~ /axiom[ \t]+[A-Za-z0-9_'"'"']+[ \t]*<-/) ? " <-" : ""
                 print $1, kw, name r }' | LC_ALL=C sort)
  echo "EasyCrypt library lines found: $(wc -l < "$LOG/eclib-axioms.log" | tr -d ' ')"
  expect_list "$got" "$HERE/jasmin/ECLIB_AXIOMS" "the EasyCrypt library scan"
  echo "eclib scan: as listed in jasmin/ECLIB_AXIOMS"
}

jasmin_wrappers() {
  local b
  mkdir -p "$WORK/bin"
  for b in jasminc jasmin-ct jasmin2ec jasmin-checksafety; do
    [ -x "$TREE/compiler/$b" ] || die "$TREE/compiler/$b was not built"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$TREE/compiler/$b" > "$WORK/bin/$b"
    chmod 0755 "$WORK/bin/$b"
  done
}

# The Jasmin EasyCrypt library of this tree, installed into the switch as
# eclib's own `install` target does, without writing into the tree.
jasmin_eclib() {
  local lib
  lib=$(opam var lib)/easycrypt
  rm -rf "$lib/jasmin"
  install -d "$lib/jasmin" "$lib/config"
  install -m 0644 "$TREE"/eclib/*.ec "$lib/jasmin/"
  printf '[general]\nidirs = Jasmin:%s\n' "$lib/jasmin" > "$lib/config/jasmin.conf"
}

step_jasmin() {
  say "jasmin"
  check_inputs
  use_switch
  if [ "$EASYCRYPT" = 1 ]; then
    command -v easycrypt >/dev/null \
      || die "switch $SWITCH has no EasyCrypt; run the switch step, or use --no-easycrypt"
  fi
  jasmin_tree
  jasmin_provenance
  say "proofs"
  $NICE make -C "$TREE/proofs" -j"$JOBS" all > "$LOG/proofs.log" 2>&1 \
    || { tail -30 "$LOG/proofs.log"; die "proofs failed, see $LOG/proofs.log"; }
  say "extraction"
  # Nothing generated survives from an earlier build: the extraction
  # directory and the compiler's copy of it are emptied of untracked files
  # (`make CIL` then extracts again from the checked proofs).
  git -C "$TREE" clean -fdxq -- proofs/lang/ocaml compiler/src/CIL
  $NICE make -C "$TREE/compiler" CIL > "$LOG/extraction.log" 2>&1 \
    || { tail -30 "$LOG/extraction.log"; die "extraction failed"; }
  cil_hashes > "$LOG/cil.sha256"
  say "compiler"
  $NICE make -C "$TREE/compiler" -j"$JOBS" all > "$LOG/compiler.log" 2>&1 \
    || { tail -30 "$LOG/compiler.log"; die "compiler build failed"; }
  [ "$(cil_hashes)" = "$(cat "$LOG/cil.sha256")" ] \
    || die "the extracted OCaml changed during the compiler build"
  [ -z "$(tree_status)" ] \
    || die "the build modified or added files of $TREE"
  say "assumptions"
  jasmin_assumptions
  say "admit scans"
  jasmin_admit_scan
  jasmin_eclib_scan
  # Recorded only: the binaries depend on the host and are not compared.
  (cd "$TREE/compiler" && sha256_of jasminc jasmin-ct jasmin2ec jasmin-checksafety) \
    > "$LOG/binaries.sha256"
  cat "$LOG/binaries.sha256"
  jasmin_wrappers
  if [ "$EASYCRYPT" = 1 ]; then jasmin_eclib; fi
  say "jasmin done"
}

# ---------------------------------------------------------------------------
# test

step_test() {
  say "test"
  use_switch
  [ -x "$TREE/compiler/jasminc" ] || die "no compiler in $TREE; run the jasmin step"
  jasmin_tree_check
  # Every test runs again: dune builds and runs them in a build directory
  # of their own, emptied first, with its cache, which would restore
  # recorded results, disabled.
  rm -rf "$TREE/compiler/_build-test"
  (cd "$TREE/compiler" && DUNE_CACHE=disabled $NICE dune build \
     --build-dir _build-test --display short -j "$JOBS" @tests/runtest) \
    > "$LOG/test.log" 2>&1 \
    || { tail -50 "$LOG/test.log"; die "compiler tests failed, see $LOG/test.log"; }
  # The outputs of the test executables that ran, in the emptied directory.
  (cd "$TREE/compiler/_build-test/default" \
     && find tests -name '*.output' | LC_ALL=C sort) > "$LOG/test-suites.txt"
  [ -s "$LOG/test-suites.txt" ] || die "no compiler test ran"
  echo "test suites run: $(wc -l < "$LOG/test-suites.txt" | tr -d ' ')" \
       "(test-suites.txt; cram tests leave no output file)"
  if [ "$EASYCRYPT" = 0 ]; then
    echo "eclib: not checked (--no-easycrypt)"
    echo "eclib check: not run (--no-easycrypt)" >> "$LOG/provenance.txt"
    say "test done"
    return
  fi
  say "eclib"
  # An SMT call can miss its time limit on a loaded host. A failed check
  # runs once more with one job; both logs are kept, and the build stops
  # only if the second run fails too.
  rm -f "$LOG/eclib-retry.log"
  if (cd "$TREE/eclib" && $NICE easycrypt runtest -jobs "$JOBS" tests.config jasmin) \
       > "$LOG/eclib.log" 2>&1; then
    tail -3 "$LOG/eclib.log"
    echo "eclib check: passed on the first run" >> "$LOG/provenance.txt"
  else
    grep -A20 '^Failed files' "$LOG/eclib.log" || true
    echo "eclib: failed with $JOBS jobs; checking again with one job (eclib-retry.log)"
    (cd "$TREE/eclib" && $NICE easycrypt runtest -jobs 1 tests.config jasmin) \
      > "$LOG/eclib-retry.log" 2>&1 \
      || { tail -50 "$LOG/eclib-retry.log"
           die "eclib check failed twice, see $LOG/eclib.log and eclib-retry.log"; }
    tail -3 "$LOG/eclib-retry.log"
    echo "eclib check: failed with $JOBS jobs, passed on the retry with one job" \
      >> "$LOG/provenance.txt"
  fi
  say "test done"
}

case $STEP in
  switch) step_switch ;;
  jasmin) step_jasmin ;;
  test)   step_test ;;
  all)    step_switch; step_jasmin; step_test ;;
esac
