---
name: design
description: >-
  Use when the user asks to design a workflow, command or other change with a peer,
  or asks for a peer discussion of findings.
argument-hint: "[<question | findings file>] [<harness>(<model>)] [--slug <topic>]"
---
# `/@PLUGIN@:design`

Agree on a design with the @PEER@ and present it for the user's decision. The
`@PLUGIN@:peer-chat` engine owns delivery, asks, timers, recovery and peer identity.

## Intake

1. Parse one question or file path, optional peer (same forms as Build, including `--peer`), and
   `--slug`. Read a supplied file in full as evidence. User authorization comes from the conversation.
2. Quote the user's words verbatim. Record their rulings, constraints (including unattended operation,
   deadlines and team scope when relevant) and required outcome. Ask about a constraint only if the
   design depends on it.
3. Fix one coordinator repo and slug for design and build. Default to a short kebab-case title.
   Use a single slug without path separators on every send and in the eventual build invocation.

## Engine

Apply the topic setup below during preflight, before opening the conversation.

@ENGINE@

@DESIGN_TOPIC@

## Research and challenge

1. Independently inspect the current code, callers and precedent. Save runnable probes and receipts
   in the topic directory. When redesigning an existing artifact, ask the peer for a cold read before
   presenting your proposal.
2. Open with the exact user constraints, evidence and one design question. Keep the competing
   options in chat. Accept a factual claim with a named check. Use the engine's proof procedure for
   disputed runtime behavior.
3. Walk each caller's integration, the normal path and material failures, retries and exits. Name
   who can make each decision, where it is enforced and what it costs.
4. Reuse the engine's blocking-ask timers for answers the next step needs. Settle delivery
   uncertainty before retrying. A timer expiry leaves the underlying requirement unresolved.

@LIFECYCLE@

## Converge

1. When the design is ready, write its exact presentation text as `proposal-vN.md` in the ignored
   topic directory. Include numbered decisions, affected callers and files, costs, failure paths,
   acceptance checks, open choices and a recommendation, scope exclusions and `[ASSUMPTION]`s.
   Create the file exclusively with owner-only permissions. Reuse an existing revision only for
   identical bytes.
2. Hash the file with SHA-256 and share its path and digest with the peer. Both peers read the
   exact file and send a `🏁` that names the same revision and SHA-256. Record the actual received
   closing messages with the engine's receipt procedure.
3. Read `@ASK_STATE@` through the engine status command. Verify both closing message IDs belong
   to this run, reference this revision, come from distinct bound peers and have recipient
   evidence (acknowledged or answered). Require zero open asks, unresolved messages and timer
   intents. A declined requirement stays visible in the open choices. Present a draft if the gate
   cannot pass.
4. Present the proposal verbatim with both closing message IDs and the digest as separate receipts.
   Stop at presentation until the user explicitly authorizes implementation of that revision.

## Amend or hand off

- Material changes to behavior, scope, constraints or acceptance go back to the peer. Record any
  changed proposal bytes as a new immutable revision and obtain both closes and fresh user approval.
- On resume, recover the exact proposal, peer receipts and user decision. Repeat the hash and
  ledger checks before handing off. Stale or mismatched receipts return to convergence.
- On the user's explicit go-word, carry the proposal's absolute path, digest, coordinator, slug and
  the actual approval turn into Build. @DESIGN_HANDOFF@
- Build Phase 0 writes the only `design.md` snapshot and owns fresh context. The engine's ordinary
  file ownership and build checks apply after the handoff.
