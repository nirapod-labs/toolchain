# Releasing

A release is a tag `YYYY.MM.N`. The CI workflow builds the three platforms
from scratch, as for every pull request, and publishes the bundles as a
GitHub release.

## Assets

| Asset | Contents |
|---|---|
| `toolchain-<release>-<platform>-compiler.tar.gz` | the four tools, their build record, Jasmin's EasyCrypt library |
| `toolchain-<release>-<platform>-switch.tar.zst` | the opam root |
| `toolchain-<release>-<platform>-provenance.txt` | the build's provenance |
| `SHA256SUMS` | of all of the above |

`scripts/toolchain.sh install` checks the downloaded bundles against
`SHA256SUMS` and then verifies that the installed binaries are those of the
build record. A bundle only works under `/opt/nirapod-toolchain`, where it
was built.

## Making a release

1. In the fork, rebuild `integration` on upstream `main` and tag its head
   `nirapod-<release>`.
2. In this repository, set `JASMIN_TAG`, `JASMIN_COMMIT` and `JASMIN_BASE` in
   `jasmin/PIN`, update `jasmin/ADMITS` and `jasmin/ASSUMPTIONS` if the build
   says so, add a `## <release>` section to `CHANGELOG.md`, and merge the pull
   request into `main` once its CI passes.
3. Tag the merge commit `<release>` and push the tag. The `release`
   environment asks for approval before anything is published.

Before publishing, the release job checks that `JASMIN_TAG` is
`nirapod-<release>`, that this tag on the fork points at `JASMIN_COMMIT`,
and that `CHANGELOG.md` has a `## <release>` section. The release notes are
that section followed by the Jasmin commit, its upstream base and the
first-parent commits of `integration`, taken from the provenance of
`linux-x86_64`.

## Publishing again without a rebuild

When the builds of a tag pass and publishing fails, the bundles stay with
the tag's run for seven days. Once the cause is fixed on `main`, run the
workflow by hand on `main` with `release` set to the tag and `bundles-run`
set to the ID of the tag's run:

```sh
gh workflow run ci.yml --ref main -f release=2026.11.1 -f bundles-run=<run id>
```

That run builds nothing. Its release job checks that the given run was the
push of that tag and built the tagged commit, makes the checks above, and
publishes those bundles after approval in the `release` environment.

## A failed build

A failed build uploads its logs and the actual outputs of the compiler's
test suites (`*.output`, `*.corrected`) as the artifact
`failure-<platform>`, kept for seven days, so that a changed expected output
can be read and, when the change is intended, committed to the fork's
integration.
