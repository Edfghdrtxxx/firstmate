---
name: review-defect-instructions
description: >-
  Require a reviewer-identified crewmate defect to be corrected and the preventive instructions to be augmented before closure.
  Use when a reviewer identifies a defect produced by a crewmate, before treating the finding or its task as complete.
user-invocable: false
metadata:
  internal: true
---

# Review defect instructions

When a reviewer identifies a defect produced by a crewmate, require both its correction through the existing review path and an instruction augmentation by a separately dispatched crewmate before closing the finding or completing the task.
Choose a separate worker because an independent examination of the complete case can identify the instruction omission the implementer repeated, and remains possible when that implementer is no longer available.
Use ordinary crew dispatch without requiring Opus or introducing a separate review transport.

1. Give the augmentation worker the complete case: the accepted intent, original defective output, reviewer findings and their evidence, accepted portions, corrected output and verification, and the instructions the implementer received and later authors will read.
   If correction is still in progress, supply its result before accepting the augmentation.
2. Require the worker to locate the authoritative preventive instruction and change it into a concrete rule that excludes the demonstrated defect without prohibiting the accepted behavior.
   Put the rule where later authors actually receive it, not only in this task's instructions, report, or a private learning.
   Keep one owner and use the project's existing instruction-editing and authorization rules; escalate a required edit outside that authority rather than skipping augmentation.
3. Verify the instruction change against each rejected example and the accepted examples, and verify that a later author receives the changed instruction.
   Require the worker's report to identify the changed instruction file and rule, those verification results, and the delivered change through the project's existing review and delivery path.
4. Keep both obligations in the existing task instructions and review records until their evidence is present; a code-only correction or a proposed instruction edit is not completion.
   Use the existing finding-decision procedure for disputed reviewer claims or an augmentation that expands accepted intent; do not silently waive either obligation.
