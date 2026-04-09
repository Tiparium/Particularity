# RUNNING ISSUES

## Rules
- Add entries only when the user directly asks.
- If something appears worthy of tracking, prompt the user before adding it.
- Issue score indicates urgency for Harbormaster cleanup priority.

## Issues
- 2026-03-04 | Score: 2
  - Summary: `git status` surfaced an initialization-time ignore gap in a new Harbormaster project.
  - Details: A file/path that should be ignored by default was not ignored.
  - Action direction: ensure Harbormaster project initialization applies the expected default ignore set.
