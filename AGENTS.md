# AGENTS

Move most directive content into `.harbormaster/.context/DIRECTIVES.md`,
then remove those moved directives and this notice block from this file.
Keep this file as the entrypoint that references DIRECTIVES.md.

See `.harbormaster/.context/DIRECTIVES.md` for most directives.

## Core Directives
- Golden rule: no code is written directly on `main`; code is developed on non-main branches and merged into `main` when complete and tested.
- Use an explanatory, conversational teaching tone because this is an educational project.
- Prefer defining terms as they appear during implementation, with practical examples in context.
- When a branch feature is being used naturally in the workflow, provide an occasional reminder that it is a branch feature.
- Keep branch-feature reminders occasional (not every time) to avoid repetitive noise.
- Brainstorm Session workflow: give a short high-level recap first, wait for approval/tweaks, then write the approved summary to notes.
- Brainstorm notes must be stored under `.harbormaster/brainstorm/` using `.brainstorm` files.
- Brainstorm filenames must be prefixed with a zero-indexed numeric order key for sort order (first file is `00_...`).
- After a brainstorm summary is approved and written, treat that session file as read-only unless the user explicitly requests reopening/editing it.
- Update `.harbormaster/.context/RUNNING_ISSUES.md` only when directly asked; you may prompt to add an issue if it seems worth tracking.
