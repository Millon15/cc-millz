---
name: code-style
description: >
  The user's personal code taste — declarative orchestrators
  + small intent-named helpers (SLAP), flat control flow, no narrating comments, pure helpers, typed VOs, fail-fast
  + decoded principles (DRY/YAGNI/KISS/SOLID/…) 
  + patterns-to-reach-for menu
  Personal preference — apply to ALL code you work with
when_to_use: >
  Load BEFORE writing, refactoring, extracting, simplifying, or reviewing ANY production code
  for this user — new methods/classes/endpoints, cleanups, unit tests, code reviews.
  Trigger on: refactor, extract, simplify, clean up, restyle, review my code,
  new service/class/method/component.
---

# Code Style (personal — all projects)

My taste. Apply to ALL code you write/refactor.

## Core

- **Declarative, description-driven is the pivot.** Orchestrator methods read like the algorithm — thin method names the steps, each step a small intent-named helper. Methods <20 lines; 20–80 OK only for a non-splittable complex algo (crypto, math, calc with many interdependent locals).
- **SLAP — one abstraction level per method.** All statements at the same conceptual altitude; no orchestration mixed with low-level detail. Litmus: need a comment to head a *section*? That section wants to be its own method.
- **Flat control flow.** Guard clauses + early returns; no nested conditionals, no `else` after return; preconditions asserted at top.
- **Names carry meaning.** Intent-revealing verb-phrase methods; call site reads as prose — this is what lets comments vanish.
- **No narrating comments.** Code self-explains. Docblocks are hints, not docs: method = ≤1-sentence algo summary, and only when the name doesn't already say it (>1 sentence = refactor smell); class = terse pointers (ticket link, a heavily-used collaborator) + visual aids (decision tables, lists). Only in-body comment allowed: a constraint the code can't express (load-bearing ordering, spec/ticket reason).
- **Pure over mutating.** Helpers never mutate their args — clone-before-mutate.
- **Typed value objects over arrays.** Small readonly VOs/DTOs, not associative arrays.
- **Canonical class layout.** All members declared at the top in fixed order — constants → properties → constructor → public → protected → private methods. NEVER strand a `const`/property in the middle of the class between methods.
- **Reach for modern language features.** Prefer the newest constructs the runtime supports over legacy idioms — e.g. in PHP 8.0+: constructor property promotion, `match`, enums, readonly props, named args, nullsafe `?->`, first-class callables, and typed class constants (8.3). Use them wherever they make intent clearer; don't hand-roll what the language now gives you.
- **Fail fast.** Throw on caller/programmer-bug preconditions (message says what + why); defensive fallback only for expected/external bad input.
- **Thread args explicitly;** bundle into a context object only when arg count hurts readability.
- **Tests are declarative too.** Data-provider-driven, one behaviour per case; prove a refactor by re-running the same suite green (parity); real-data E2E on money/critical paths.

## Principles, decoded (my take, not textbook)

- **DRY** — dedupe *knowledge*, not characters. Rule of three: abstract on the 3rd+ duplication; a little duplication beats a wrong abstraction.
- **YAGNI** — no abstraction for imagined futures; extraction justified by 2+ real reasons *today* is warranted, not a violation.
- **KISS** — simplest that *expresses intent*, not fewest lines. Explicit beats clever.
- **SOLID** —
    * **S**: one reason to change (carries separation-of-concerns).
    * **O**: extend by adding a small unit, not editing the dispatcher.
    * **L**: an impl honours its interface contract — no surprises when swapped.
    * **I**: narrow interfaces; a caller sees only what it uses.
    * **D**: depend on injected abstractions (constructor DI), not concretions.
- **Composition over inheritance** — injected services + traits, not deep hierarchies.
- **Law of Demeter** — no reach-through foreign internals; a fluent chain on your *own* VO is fine.
- **Least astonishment** — a method does what its name/signature promise; no hidden side effects.

## Patterns to reach for

(when they fit — never forced; follow AHA and rule of three!)

- **Strategy / decision-table** — branch selection as a dispatch table, each arm a named unit.
- **Value Object** — small immutable typed values (money/domain), not primitives/arrays.
- **Result / DTO** — a named struct for multi-value returns, not a tuple/array.
- **Null Object / Optional** — explicit empty/absent over a bare null + null-checks.
- **Repository** — data access behind a repo interface, not inline queries in services.
- **Adapter (Ports & Adapters)** — wrap unstable externals (gateways, supplier APIs) behind a stable port.
- **Information-Expert (GRASP)** — method lives on the class owning the data, not an external calc reaching in via getters.
- **CQS** — command (mutate, void) XOR query (pure return), never both; pragmatic exceptions (stack pop, `INSERT … RETURNING`).
- **Factory** — centralize non-trivial construction.
- **Fluent builder** — readable stepwise assembly.
- **Anti-corruption layer** — translation boundary to a foreign model, at real integration seams.
