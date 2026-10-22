# Marimo implementation plan

1. Inspect current upstream CLI, login, and reverse proxy behavior; confirm Sherlock runtime availability.
2. Write failing tests for rendered form/resources, private authenticated lifecycle, quoting, startup failure, and login view.
3. Implement independent app templates and preinstalled Python runtime selection.
4. Test with marimo in an isolated local environment, including login, editor, prefixed assets, and authenticated WebSocket.
5. Document one-time installation, usage, tests, and the remaining Sherlock deployment acceptance check; self-review and hand back for independent review.
