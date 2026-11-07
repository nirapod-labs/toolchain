# Nirapod toolchain

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![CI](https://github.com/nirapod-labs/toolchain/actions/workflows/ci.yml/badge.svg)](https://github.com/nirapod-labs/toolchain/actions/workflows/ci.yml)

## About

The Jasmin and EasyCrypt toolchain that Nirapod's verified cryptography is
built and proved with. One release names one Jasmin compiler, from the
`integration` branch of the fork
[nirapod-labs/jasmin](https://github.com/nirapod-labs/jasmin), one EasyCrypt,
one set of SMT provers and one opam switch, and ships them built for three
platforms, so a component's CI installs the toolchain instead of building it.

| Platform | Runner | Contents |
|---|---|---|
| `linux-x86_64` | `ubuntu-24.04` | compiler, switch with EasyCrypt, Why3 and the provers |
| `linux-aarch64` | `ubuntu-24.04-arm` | compiler, switch without EasyCrypt |
| `macos-aarch64` | `macos-26` | compiler, switch with EasyCrypt, Why3 and the provers |

What is pinned, and why, is in [pins](docs/PINS.md). What the build
checks is in [building](docs/BUILDING.md), and how a release is made
in [releasing](docs/RELEASING.md).

## Using the toolchain

- in GitHub Actions

  ```yaml
  - uses: nirapod-labs/toolchain/.github/actions/setup@<commit of the release tag>
    with:
      release: 2026.11.0
      parts: compiler switch      # or: compiler, for jobs that run no EasyCrypt
  ```

- on a machine of your own (Linux or macOS on Apple silicon)

  ```sh
  scripts/toolchain.sh deps run
  scripts/toolchain.sh install 2026.11.0
  eval "$(scripts/toolchain.sh bin-path)"
  ```

`jasminc`, `jasmin-ct`, `jasmin2ec` and `jasmin-checksafety` are then on
`PATH`. EasyCrypt runs in the switch's own environment, where Jasmin's
EasyCrypt library is configured as `Jasmin`:

```sh
nirapod-toolchain exec easycrypt compile proof.ec
```

The toolchain lives in `/opt/nirapod-toolchain` on every platform; `install`
creates the directory with `sudo` the first time.

## Building

- Linux on x86-64, macOS on Apple silicon

  ```sh
  ./build.sh all
  ```

- Linux on AArch64, where several pinned provers publish no binaries

  ```sh
  ./build.sh --no-easycrypt all
  ```

## Getting support

Questions and bug reports go to the
[issue tracker](https://github.com/nirapod-labs/toolchain/issues).

## License

This repository is licensed under the [Apache License 2.0](LICENSE). Every
file names its licence in an SPDX header or in [REUSE.toml](REUSE.toml). The
tools it pins are under their own licences.
