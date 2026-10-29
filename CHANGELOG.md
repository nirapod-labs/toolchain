# Changelog

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
