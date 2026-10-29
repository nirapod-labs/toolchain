# Nirapod toolchain

The Jasmin and EasyCrypt toolchain that Nirapod's verified cryptography is
built and proved with. One release names one Jasmin compiler, one EasyCrypt,
one set of provers and one opam switch, and ships them built for three
platforms, so a component's CI installs the toolchain instead of building it.

| Platform | Runner | Contents |
|---|---|---|
| `linux-x86_64` | `ubuntu-24.04` | compiler, switch with EasyCrypt, Why3 and the provers |
| `linux-aarch64` | `ubuntu-24.04-arm` | compiler, switch without EasyCrypt (several pinned provers publish no AArch64 Linux binaries) |
| `macos-aarch64` | `macos-26` | compiler, switch with EasyCrypt, Why3 and the provers |

## What is pinned

- **Jasmin**: a commit of the `integration` branch of
  [nirapod-labs/jasmin](https://github.com/nirapod-labs/jasmin), tagged
  `nirapod-<release>` (`jasmin/PIN`). In the fork each change is a topic
  branch, one upstream pull request each; `integration` is a commit of
  upstream `main` with every topic merged into it, plus the expected test
  outputs of the combination. When upstream merges a topic, the next
  integration no longer carries it.
- **EasyCrypt**: a commit (`easycrypt/PIN`).
- **Provers**: release binaries by version and SHA-256 (`easycrypt/PIN`).
- **opam**: the release binary by SHA-256 (`scripts/toolchain.sh`), and the two
  package repositories by commit (`jasmin/PIN`). The switch must hold exactly
  `opam-packages.txt`.

Only Jasmin is ours to build. Everything else is installed at its pinned
version from its own release.

## Using a release

In GitHub Actions:

```yaml
- uses: nirapod-labs/toolchain/.github/actions/setup@<commit of the release tag>
  with:
    release: 2026.11.0
    parts: compiler switch      # or: compiler, for jobs that run no EasyCrypt
```

`jasminc`, `jasmin-ct`, `jasmin2ec` and `jasmin-checksafety` are then on
`PATH`. EasyCrypt runs in the switch's own environment, where Jasmin's
EasyCrypt library is configured as `Jasmin`:

```sh
nirapod-toolchain exec easycrypt compile proof.ec
```

On a machine of your own (Linux or macOS on Apple silicon):

```sh
scripts/toolchain.sh deps run
scripts/toolchain.sh install 2026.11.0
eval "$(scripts/toolchain.sh bin-path)"
```

The toolchain lives in `/opt/nirapod-toolchain` on every platform. The opam
switch records absolute paths, so a bundle only works where it was built;
`install` creates the directory with `sudo` the first time.

## Building

```sh
./build.sh all                    # Linux on x86-64, macOS on Apple silicon
./build.sh --no-easycrypt all     # Linux on AArch64
```

`./build.sh switch`, `jasmin` and `test` run one step. The work directory is
`./work` unless `WORK` is set; release bundles are built with
`WORK=/opt/nirapod-toolchain`. A cold build took 29 minutes on GitHub's
`ubuntu-24.04`, 18 on `ubuntu-24.04-arm` and 45 on `macos-26` (measured in
nirapod-slhdsa's CI, which this repository's build comes from).

What the build checks, and stops on:

- the switch holds exactly `opam-packages.txt`, from the two pinned opam
  repositories only;
- Why3 knows only the pinned provers, by name and version;
- the Jasmin tree is exactly the pinned commit, with the pinned upstream base
  among its ancestors;
- `make -C proofs` checks the whole Rocq development, compiler correctness
  included;
- every `Admitted`, `admit`, `Abort`, `Axiom`, `Parameter`, `Hypothesis` and
  `Conjecture` of the Rocq tree is listed in `jasmin/ADMITS`, every axiom of
  Jasmin's EasyCrypt library in `jasmin/ECLIB_AXIOMS`, and `Print Assumptions`
  of the compiler theorem and the two architecture records matches
  `jasmin/ASSUMPTIONS`;
- the extracted OCaml is regenerated from the proofs and unchanged by the build;
- the compiler's test suites pass, and Jasmin's EasyCrypt library checks with
  the pinned EasyCrypt.

The hand-written OCaml of the compiler (front end, printers, the
constant-time and safety checkers) is outside the Rocq proofs.

`logs/provenance.txt` in the work directory records the inputs, the host, the
topics merged on the upstream base and every commit they carry.

## Releases

A release is a tag `YYYY.MM.N` on `main`. The workflow builds the three
platforms from scratch, as for every pull request, and publishes:

| Asset | |
|---|---|
| `toolchain-<release>-<platform>-compiler.tar.gz` | the four tools, their build record, Jasmin's EasyCrypt library |
| `toolchain-<release>-<platform>-switch.tar.zst` | the opam root |
| `toolchain-<release>-<platform>-provenance.txt` | the build's provenance |
| `SHA256SUMS` | of all of the above |

To make one:

1. In the fork, rebuild `integration` on upstream `main` and tag its head
   `nirapod-<release>`.
2. In this repository, set `JASMIN_TAG`, `JASMIN_COMMIT` and `JASMIN_BASE` in
   `jasmin/PIN`, update `jasmin/ADMITS` and `jasmin/ASSUMPTIONS` if the build
   says so, add a `## <release>` section to `CHANGELOG.md`, and merge the pull
   request once its CI passes.
3. Tag the merge commit `<release>` and push the tag. The `release`
   environment asks for approval before anything is published.

A failed build uploads its logs and the actual outputs of the compiler's test
suites (`*.output`, `*.corrected`), so that a changed expected output can be
read and, when the change is intended, committed to the fork's integration.

## Layout

```
build.sh               builds the toolchain
jasmin/PIN             the fork commit, its upstream base, OCaml, the opam repositories
jasmin/ASSUMPTIONS     the expected `Print Assumptions` reports
jasmin/ADMITS          the expected unfinished or assumed declarations
jasmin/ECLIB_AXIOMS    the expected axioms of Jasmin's EasyCrypt library
easycrypt/PIN          EasyCrypt and the provers
opam-packages.txt      the exact package set of the switch
scripts/toolchain.sh   host packages, bundles, install, verify, exec
.github/actions/setup  the action components use
.github/workflows/     ci.yml: lint, build on three platforms, release from a tag
```

## Licence

Apache-2.0. The tools this repository pins are under their own licences.
