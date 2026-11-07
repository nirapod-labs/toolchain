# Changelog

## 2026.11.1

- Jasmin: upstream `main` of 2026-11-07 (`af6e17f`) with 18 topics merged.
  - Dropped, now upstream: the Mach-O relocations (#1594) and the report of
    unbounded memory ranges (#1672); the first three commits of the safety
    pass (#1572), the total mode of the operators, the variable map and the
    expressions.
  - Added: `PSTATE.DIT` in ARMv8-A export functions (#1678).
  - Adapted to upstream: the safety pass and its EasyCrypt translation to
    the for-to-while pass of `jasmin2ec` (#1666), the ARMv8-A SIMD lowering
    proof to the min and max operators, the SIMD printer to the removal of
    UXTW, and the tests to the cortex-m3 target (#1611).
- The environment, EasyCrypt and the provers are those of 2026.11.0.

## 2026.11.0

The first release. The toolchain that nirapod-sha2 and nirapod-slhdsa built
in their own `toolchain/` directories, moved here. Their patch series is now
the fork nirapod-labs/jasmin: one topic branch per change and an
`integration` branch that merges them.

- Jasmin: upstream `main` of 2026-10-29 (`6c4994d`) with 18 topics merged:
  the ARMv8-A Advanced SIMD and SHA-2/SHA-3 instructions, the Mach-O
  relocations, armv8a code generation fixes, the safety pass with its
  EasyCrypt translation, and the safety checker changes.
- EasyCrypt `e7eff05d`, OCaml 4.14.4, Rocq 9.0, as in both components.
