# Effective acceptance and review handoff

Use this brief when handing an implementation to a reviewer or requesting a
regrade. It captures the current agreement beside the original ticket, so the
reviewer does not reconstruct amendments from old prompts or research plans.
Keep only fields relevant to the task. This is a repository-local handoff;
external dispatch/review skills retain their own invocation contract.

## Brief template

```text
Task: <issue/spec link and requested outcome>
Effective acceptance:
- <behavior that must hold, including current user amendments>
Amendments and provenance: <message/date or updated spec; what it supersedes>
Scope limits: <allowed paths/actions and explicit exclusions>

Checkout: <absolute worktree path and branch>
Base: <full SHA>
Candidate: <full SHA, or explicitly uncommitted scope>
Working tree: <git status --short; identify pre-existing changes>
Correction delta, for a regrade: <previous candidate..current candidate>

Implementation route: <entry → state owner → transport seam>
Required checks: <lane/suite, platform or UI acceptance requirements>
Evidence:
- <candidate SHA; command; passed/failed/not run; executed count; artifact>
External evidence: <provided logs, their SHA/platform, and unverified limits>
Remaining acceptance: <specific requirement and missing evidence, or none>
Handoff ownership: <leave the named Simulator/app running if requested>
```

Pin base, candidate, and working-tree scope before a fixed-SHA review. If the
candidate or dirty-file set changes during that review, report the integrity
change and repeat from a stable scope. Preserve unrelated work.

A regrade assesses the complete corrected candidate and its correction delta.
Earlier-candidate, parent, or supplied logs retain their original provenance.
Report source/static review, executed tests, fixture SSH, native UI, device,
live-service, and publication evidence separately where they matter.
