# LeanIO in this repository

Vendored from `ecyrbe/leanio` at revision `0bb212d57f3dba2d76cf601f76a7c431a51c902e`, MIT licensed
(see `LICENSE`). The copy is the library and its tests; the upstream examples are not vendored yet.

Compatibility edits applied for the shared toolchain (`Lean 4.35.0`):

- `Data/Headers/HeaderName.lean`: removed `contentEncoding`, `ifNoneMatch`, `lastModified` and
  `ifModifiedSince`, which `Std.Http.Header.Name` now provides. No other source changes.

Test modules moved from `Tests.*` to `LeanIO.Tests.*` so they live inside the vendored namespace.

Porting work — a native LeanIn backend, body streams and the session seam — is described in
`docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`.
