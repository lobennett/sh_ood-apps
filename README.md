# Open OnDemand apps for Sherlock

This repository contains [Open OnDemand](https://openondemand.org/) used on
[Sherlock](https://www.sherlock.stanford.edu)

## `sh_jupyter`

Local customizations for [Jupyter](https://jupyter.org/) notebooks, based on
https://github.com/OSC/bc_osc_jupyter

## `sh_rstudio`

Local customizations for [RStudio
Server](https://rstudio.com/products/rstudio/), based on
https://github.com/OSC/bc_osc_rstudio_server

## `sh_tensorboard`

OnDemand app for [Tensorboard](https://www.tensorflow.org/tensorboard)

Because Tensorboard doesn't provide any kind of authentication mechanism, this
app adds an transparent authentication layer, via an authenticating reverse
proxy and session cookies. The workflow is transparent for users, but
Tensorboard sessions can only be accessed through the OnDemand portal. 

## `sh_code-server`

Local customizations for [code-server](https://coder.com/docs/code-server),
based on https://github.com/OSC/bc_osc_codeserver

## `sh_matlab`

OnDemand app for Matlab, using
[matlab-proxy](https://github.com/mathworks/matlab-proxy)

## `sh_herdr`

Open OnDemand app for persistent [Herdr](https://herdr.dev) agent workspaces
on Sherlock compute nodes. See [`sh_herdr/README.md`](sh_herdr/README.md) for
setup, attachment, and troubleshooting instructions.

## `sh_supacode`

Reserve a Sherlock compute allocation for [Supacode](https://supacode.sh/) on
your Mac and launch Claude Code or Codex in a remote workspace. See
[`sh_supacode/README.md`](sh_supacode/README.md) for SSH setup and usage.

## `sh_marimo`

Launch an editable [marimo](https://marimo.io/) notebook server in your browser
through OnDemand, using a preinstalled Python environment. See
[`sh_marimo/README.md`](sh_marimo/README.md) for installation and usage.

## `sh_agentic-engineering`

Launch a persistent Herdr session on a Sherlock compute node with the public
[agentic-engineering](https://github.com/lobennett/agentic-engineering) setup
(Firstmate plus Claude Code, Codex, or Pi) already running in your Firstmate
home, and attach through OnDemand's own shell. See
[`sh_agentic-engineering/README.md`](sh_agentic-engineering/README.md) for the
one-time setup, attachment, and session ownership rules.

## Installing the sandbox apps

Sherlock provides the Jupyter, RStudio, TensorBoard, code-server, and MATLAB
apps system-wide. The newer apps (`sh_herdr`, `sh_supacode`, `sh_marimo`, and
`sh_agentic-engineering`) run from your own OnDemand development directory.
On a Sherlock login node, clone this repository and register them:

```bash
git clone https://github.com/lobennett/sh_ood-apps.git ~/src/sh_ood-apps
bash ~/src/sh_ood-apps/install-apps.sh
```

The script symlinks each app from the checkout into `~/ondemand/dev`, so
`git pull` updates them in place. It is safe to rerun: existing links into the
checkout are left as they are, a real file or directory at an app's path is
never removed, and a symlink pointing elsewhere is left alone and reported so
you can move it aside. The apps then appear under **Develop → My Sandbox
Apps**.

That menu is shown only after the Sherlock team has enabled app development
for your account (a symlink under `/var/www/ood/apps/dev/<user>` described in
Open OnDemand's
[Enabling App Development](https://osc.github.io/ood-documentation/latest/how-tos/app-development/enabling-development-mode.html)
page). The installer cannot perform that step; ask Sherlock support if the
Develop menu is missing.

Repository-level tests: `bash test/run`. Each app also has its own suite, for
example `bash sh_agentic-engineering/test/run`. GitHub Actions
(`.github/workflows/ci.yml`) runs the installer, Agentic Engineering, and Herdr
suites on every push and pull request.
