# Agentic Engineering implementation plan

1. Inspect the feature branch's Herdr, Supacode, and Marimo apps, the OnDemand batch-connect wrapper, Herdr's CLI and socket documentation, and the agentic-engineering installer interface published by its worker.
2. Check the needed Herdr CLI calls (status, workspace list/create, pane run) against a real local Herdr in an isolated lab session.
3. Write the app: form, submit with a session-named Slurm job, before/script/after hooks, staged attach helper, connection view, and `bin/setup` for the public setup.
4. Write `install-apps.sh` at the repository root with idempotent, conflict-refusing symlink installation.
5. Cover rendering, the ownership guard, fresh and restored sessions, every startup failure, cleanup, the attach helper, setup, and the installer with local tests; document usage, limits, and the remaining live acceptance check.
