# What is pinned

A release of the toolchain is fixed by the files of this repository. Each
input is pinned by commit or by SHA-256, and the build checks every one of
them (see [BUILDING.md](BUILDING.md)).

| Input | Pinned by | File |
|---|---|---|
| Jasmin | a commit of the fork's `integration` branch, tagged `nirapod-<release>`, and its upstream base | `jasmin/PIN` |
| OCaml | version | `jasmin/PIN` |
| opam package repositories | a commit of `ocaml/opam-repository` and of `rocq-prover/opam` | `jasmin/PIN` |
| mathcomp-word | commit | `jasmin/PIN` |
| Package set of the switch | the exact list of packages and versions | `opam-packages.txt` |
| EasyCrypt | commit | `easycrypt/PIN` |
| Why3 | version | `easycrypt/PIN` |
| SMT provers | release binaries, by version and SHA-256, per platform | `easycrypt/PIN` |
| opam | the release binary, by version and SHA-256 | `scripts/toolchain.sh` |

Jasmin is the only component that carries changes of ours. Everything else
is used unmodified at its pin.

## The Jasmin fork

Jasmin comes from the fork
[nirapod-labs/jasmin](https://github.com/nirapod-labs/jasmin). In the fork
each change is a topic branch, one upstream pull request each. `integration`
is a commit of upstream `main` with every topic merged into it, plus the
expected test outputs of the combination. When upstream merges a topic, the
next integration no longer carries it.

`jasmin/PIN` names three values:

- `JASMIN_COMMIT`, the commit of `integration` that is built;
- `JASMIN_TAG`, the fork's tag on that commit, `nirapod-<release>`;
- `JASMIN_BASE`, the commit of upstream `main` the topics are merged on.

The build environment follows the upstream CI at `JASMIN_BASE`: the Rocq
stack of its `default.nix` and the mathcomp-word revision of
`scripts/mathcomp-word.nix`. The comments in `jasmin/PIN` give the version
of each package and the reason for each departure.

## EasyCrypt and the provers

EasyCrypt is a commit of its `main` branch after release r2026.09, the newer
of the two versions upstream Jasmin CI checks its EasyCrypt library against.
EasyCrypt projects name provers with a minimum version, such as
`provers = Z3@4.12`, and EasyCrypt uses the lowest installed version that
satisfies it. The pinned provers are the subset of EasyCrypt's own CI image
that the developments built with this toolchain resolve to, so their proofs
run against the prover versions their CI uses. `easycrypt/PIN` lists each
prover, the projects that need it, and the two versions left out.

Linux on AArch64 has no official binaries of several pinned provers, so the
toolchain for that platform is built without EasyCrypt, Why3 and the
provers.
