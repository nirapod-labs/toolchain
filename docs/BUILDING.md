# Building the toolchain

```sh
./build.sh all                    # Linux on x86-64, macOS on Apple silicon
./build.sh --no-easycrypt all     # Linux on AArch64
```

`./build.sh switch`, `jasmin` and `test` run one step:

| Step | What it does |
|---|---|
| `switch` | the opam switch: OCaml, the Rocq libraries of the Jasmin proofs, the OCaml libraries of the compiler, EasyCrypt, Why3, the provers |
| `jasmin` | the pinned commit of the Jasmin fork, built as upstream builds it: Rocq proofs, extraction, OCaml build |
| `test` | the compiler's own test suites and Jasmin's EasyCrypt library, on the built tree |
| `all` | the three steps in order (the default) |

`--no-easycrypt` leaves out EasyCrypt, Why3 and the provers, and the test
step then does not check Jasmin's EasyCrypt library. On a platform without
pinned prover binaries the build stops unless the option is given.

The host packages the build needs, and the pinned opam, are installed by
`scripts/toolchain.sh deps build`. On Linux this relaxes a kernel setting
for unprivileged user namespaces; it is meant for a discarded CI runner,
not a host you keep.

The work directory is `./work` unless `WORK` is set; release bundles are
built with `WORK=/opt/nirapod-toolchain`, because the opam switch records
absolute paths. `JOBS` sets the number of parallel jobs (default 4). A cold
build took 29 minutes on GitHub's `ubuntu-24.04`, 18 on `ubuntu-24.04-arm`
and 45 on `macos-26` (measured in nirapod-slhdsa's CI, which this
repository's build comes from).

## What the build checks, and stops on

- this repository has no uncommitted changes;
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
  of the compiler theorem and the two architecture records (ARMv8-A and
  x86-64) matches `jasmin/ASSUMPTIONS`;
- the extracted OCaml is regenerated from the proofs and unchanged by the
  build;
- the compiler's test suites pass, and, unless `--no-easycrypt` is given,
  Jasmin's EasyCrypt library checks with the pinned EasyCrypt.

A change to any of the three lists is therefore a reviewed change. Each list
explains its entries in its header.

The hand-written OCaml of the compiler (front end, printers, the
constant-time and safety checkers) is outside the Rocq proofs.

## Provenance

`logs/provenance.txt` in the work directory records the inputs, the host,
the topics merged on the upstream base and every commit they carry. The
other logs of the build are in the same directory.

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
