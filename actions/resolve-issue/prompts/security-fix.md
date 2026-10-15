Fix the security findings reported in issue #{ISSUE} "{TITLE}":

<issue_body>
{BODY}
</issue_body>

Fix only the vulnerabilities at the `path:line` locations the issue
lists — no refactoring, renaming, or tidying of surrounding code. A
small diff is what makes the fix verifiable in review.

Before writing a fix, find how the same concern is already handled
safely elsewhere in the repository (authorization checks, input validation,
SQL construction, log masking all have established patterns) and
follow it. Do not invent a new defense mechanism.

Never make a change that merely stops the vulnerability from being
detected: disabling a lint rule, casting the type away, or adding a
suppression comment is concealment, not a fix.

If the finding is a false positive, change no code and report why it
is not exploitable. If the fix requires a dependency version bump,
change no code and report that instead — regenerating the lockfile is
a human's call.

Carry the finding's OWASP / CWE / ASVS citation into what you report,
so the finding, the fix, and the approval stay traceable as one record.
