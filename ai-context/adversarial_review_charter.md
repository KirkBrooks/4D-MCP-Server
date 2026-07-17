# Half B — Adversarial Review Charter

**Purpose:** audit the built Half B implementation against the locked wire
contract, to surface divergences the implementation's own test suite cannot
catch. The 53-assertion headless suite and 17-check curl suite were written by
the same effort that wrote the code; green means *self-consistent*, not
*correct against the contract*. This loop supplies the missing independent eye.

**This is a review, not a build.** No code is written or fixed here. Reviewers
produce findings; findings return to Kirk; design changes are his decisions
(loop-prep Phase 4).

---

## Ground truth (the oracle)

The single source of truth is **`ai-context/mcp_data_wire_contract.md` (v1)**.
Every finding must cite a specific contract clause (e.g. "§2 gate 4",
"§3.2 `limit`", "§4 `BAD_PARAMS`").

`ai-context/design_notes_halfB.md` is **context, not contract**. It records
deliberate, already-reasoned deviations and 4D-version workarounds. A reviewer
must not raise a "finding" that the design notes already explain and justify —
read the notes first, then audit what remains. In particular these are
**settled, not findings**:

- "8 actions" in the contract vs. 7 action *types* in §3.1–3.7 — resolved as
  7 types, `call_method` exercised twice = 8 invocations.
- Shared singletons hold no state; config exposed via functions — a forced 4D
  build workaround (`-10721`), not a design smell.
- Dynamic attribute access via `ds[$name][$key]` double-bracket — required;
  direct `ds.X[$attr]` throws in this build.
- Per-token rate limit + `RATE_LIMITED` (429) is a deliberate 9th code added
  to the taxonomy; contract §4 was updated to match.

---

## What counts as a finding

A finding is one of:

1. **Contract divergence** — implemented behavior differs from what a contract
   clause specifies (wrong error code, wrong gate order, wrong default, a
   response field missing or mis-shaped, a capability check that gates on the
   wrong verb).
2. **Unspecified behavior at a contract boundary** — the contract names an
   input class it does not define the handling for, and the code makes a silent
   choice that a client could reasonably be surprised by (e.g. a negative
   `limit`, a prefix-less `Authorization` header). The finding is the *gap*, not
   an assertion that the code is wrong — the resolution is Kirk's.
3. **Security / gate-integrity gap** — an ordering or check the self-written
   suite structurally cannot catch because it asserts the code's own behavior
   (e.g. a gate that can be reached before an earlier gate that should precede
   it; a capability that can be bypassed; a value string-interpolated where the
   contract promises positional binding).

Not a finding: style, naming, comment nits, anything the design notes justify,
or a test the suite "should also have" unless it maps to one of the three above.

---

## Classification (per item)

Each reviewed unit returns one of:

- **PASS** — no divergence from the cited contract clauses.
- **FINDING** — one or more items of type 1–3 above. Each carries: contract
  clause, code location (file + function + the relevant line), observed
  behavior, contract-required (or contract-silent) behavior, and severity
  (low / medium / high).
- **ESCALATE** — the reviewer cannot decide PASS vs FINDING without Kirk
  interpreting the contract, OR a high-severity security gap is suspected. An
  ESCALATE in the trial blocks scaling the batch (loop-prep Phase 6).

---

## Isolation discipline

Each item runs in its own Claude Code context via `/run-queue`. A reviewer sees
only: this charter, the wire contract, the design notes, and the one class it is
assigned. It does **not** see the other reviewers' items or this conversation —
the point is an eye that is not saturated with the rationale for every choice.

---

## Scope: the five production classes

| Class | Contract clauses it owns |
|---|---|
| `MCP_Handler` | §1 envelopes, §2 gate order + auth, §4 taxonomy + HTTP mapping |
| `MCP_DataAccess` | §3.2–3.7 execution, pagination, positional binding |
| `MCP_Auth` | §2 capability object shape + normalization |
| `MCP_Schema` | §3.1 digest shape, read-filtering, `callable_actions` no-leak |
| (cross-cutting) | §4 — every code emitted maps to the right HTTP status once |

**Trial (this batch):** `MCP_Handler` and `MCP_DataAccess` — the two highest-risk
classes (all gating; all mutation + binding). Remaining classes + the taxonomy
sweep enqueue only after a clean trial rollup.

---

## Trial gate (Phase 6 — do not scale the batch unless all hold)

- No ESCALATE in the trial.
- Low dismissal rate — reviewers finding real divergences, not inventing them.
- No item required interpreting the contract mid-flight. If one did, the
  *contract* has a hole → fix the contract, re-trial; do not paper over it in
  the item.

Recurring finding classes across the trial are charter/contract edits (commit
in the repo), not per-item patches.
