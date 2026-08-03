# PRESERVED — do not resume without an explicit decision

This branch (`agent/harden-keila-v1`) is a **hardening fork of Keila v0.30.2**, explored
as a candidate backend for the newsletter platform. As of **2026-07-30 it is SUPERSEDED**
and kept only for preservation / as an optional future-adapter reference.

**Why it's off the critical path:**
- The shipping backend is the KV + Titan-SMTP sender in `carlo-v-santiago.com`, **not Keila**.
- The operator console targets a backend-agnostic **operator contract**; Keila's remaining
  value is only as the API/domain **north-star**, and that value is already **extracted into
  the contract** (its resource nouns: contacts/segments/senders/campaigns/…). You get it even
  if this fork never runs.
- H0/H1/H2 hardening commits are preserved here so **nothing is lost**, but this fork is **not
  a runtime dependency**.

**Do NOT** continue Keila hardening, treat its test suite as a required gate, or wire it into
the platform **without a new, explicit decision from Carlo** that reverses this.

See: `newsletter-platform/docs/decisions/2026-07-30-Keila-superseded.md`
