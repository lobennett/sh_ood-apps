# Sherlock marimo notebook app

Add `sh_marimo` as a standalone Open OnDemand batch-connect app. Launch the native editable marimo notebook home page on one allocated compute node, starting in the selected workspace. Use the existing notebook proxy at `/node/HOST/PORT` and explicit marimo base URL. Resource fields cover partition, CPU, memory, optional GPUs/features, and runtime.

Sherlock's module catalog has no marimo module (checked 2026-10-21). Users install marimo once into a Python environment, then select its absolute Python executable. Launches never install packages. Additional modules are separate quoted arguments. No arbitrary extra server arguments or custom shell command field.

Each job receives a random password through Open OnDemand. Marimo reads a private password file; quiet startup avoids recording credentials. The connection view posts to marimo's login route, with HTML and path escaping. Authentication, normal CORS, and skew protection stay enabled. No public service is involved.

Validate rendered shell lifecycle, credentials and executable modes, literal field handling, resource rendering, failed startup, missing environment, and real marimo authentication/base-path/WebSocket behavior. Local tests cannot establish the final Sherlock proxy configuration; an actual OOD launch remains the deployment acceptance check.
