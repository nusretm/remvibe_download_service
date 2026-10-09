# remvibe_download_service — Working Rules

This is the repository's default engineering standard. Read the existing architecture, relevant documents and Git state before changes. Preserve documented project-specific contracts. The naming and layout rules below govern **new work**; never perform a wholesale retrofit without a separate approved checkpoint.

## Workflow and ownership
- Implement only explicitly approved, bounded checkpoints. Define goal, non-goals, authoritative owner, affected contracts, invariants, focused validation and stopping point.
- Inspect current implementations and protect known-good behavior. Do not commit, push, merge, rename or refactor unrelated work without authorization.
- Keep a small, stable core independent of provider/platform implementation detail. Specialized code owns external formats, endpoints, UI behavior and provider-specific semantics.
- Organize code by domain/subsystem and real responsibility. Avoid circular dependencies, growing generic helpers, giant classes, speculative interfaces, and repeated dispatch branches in the core.

## Naming, inheritance, and shared behavior
- Abstract classes use `Abs` (e.g. `ClassPageContentAbs`); instantiable shared base classes use `Base` (e.g. `ClassPageContentBase`). Specializations keep the conceptual prefix and append a specialization (`ClassPageContentHome`). Related enums/types preserve family naming (`ClassPageType`).
- Names must describe actual relationships. Do not invent both `Abs` and `Base` or force inheritance when not needed. Respect each language's conventions (e.g. Rust traits/composition).
- Semantically shared code repeated in sibling subclasses belongs in the lowest appropriate common ancestor; specialization-specific behavior stays with its owner. Avoid collapsing superficially similar but semantically different code.
- Before introducing a new class/method, check existing family, registry/authority, responsibility, reuse, dependency direction, and file location. Centralize stable domain identities instead of repeating raw tokens in production code.

## APIs, state, errors, resources
- Expose explicit public contracts, meaningful parameter names and predictable results. Define state/lifecycle ownership, transitions, cancellation, retry, cleanup and recovery when relevant.
- Never hide failures or silently swallow errors. Error translation belongs at the boundary that understands the error. Avoid unsafe shared mutable state and unnecessary dependencies.
- Protect filesystem integrity and native/network resources. For cross-language FFI, document ABI, types, memory ownership, error mapping and actual binary compatibility.

## Repository layout, builds and Git
- In single-language projects prefer domain/subsystem grouping. In multi-language repositories separate root `docs/`, `rust/`, `dart/`, `ui/`, `scripts/` where genuinely needed; keep domain-first organization within each. Do not rearrange existing sources simply to match a diagram.
- Generated root `build/` is Git-ignored and is the authoritative location for consumable compiled artifacts in multi-language projects. Keep compiler caches/intermediates separate as appropriate. Prepare FFI artifacts automatically and reject stale/incompatible binaries.
- Maintain technology-specific `.gitignore` rules for caches, generated output, logs, coverage and secrets; preserve source, manifests, required lockfiles, wrappers, and intentionally shipped binaries.
- Prefer existing dependencies/standard libraries and request approval before adding packages. Do not add backward-compatibility wrappers unless requested.
- For pure Dart, do **not** run `dart format` unless explicitly authorized; prefer `dart analyze`, focused tests and `dart test`.

## Review and continuity
- Check actual diff independently of implementation, including ownership, naming, inheritance, duplication, error and state behavior, dependency direction, scope and documentation.
- Tests do not define production architecture. Clearly distinguish compile/analyze, synthetic tests and real runtime/live validation; never claim a check was run when it was not.
- Read and update relevant `docs/continuity/` files according to existing project conventions, recording decisions, unresolved issues, live evidence and next checkpoints without inventing status.
- Project-specific working rules or architecture notes may refine these defaults; ask about genuine conflicts instead of silently overriding an established decision.

**Quality check:** Does the change belong naturally in the architecture, or does it merely make today's case work?

## Repository-specific application

Pure Dart download manager library: retain job/item ownership, retry/cancellation semantics, download integrity and callback lifecycle; do not move these responsibilities into generic helpers.
