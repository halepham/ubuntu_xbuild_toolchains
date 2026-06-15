# Workspace AI Guidance

This repository defines focused Agent Skills under `.github/skills/`
for the workflows agents repeatedly encounter. Each skill has a
`description` field that is used for discovery — match the user's
intent (e.g. "build", "deploy", "debug", "test on the board",
"new package") to one of these descriptions before acting.

## Skill router (workspace-specific)

Pick by the *primary verb* of the request:

| Intent                                              | Skill                              |
|-----------------------------------------------------|------------------------------------|
| Build / cross-compile / rosdep / sysroot / clean    | `arm64-cross-build`                |
| Deploy / run / launch / GDB *via VS Code tasks*     | `arm64-deploy-debug`               |
| SSH on board for agent-driven validation, OTA test  | `arm64-target-autonomous-test`     |
| Create / edit / review a ROS 2 package's structure  | `arm64-ros2-package-conventions`   |

If two could apply, follow the workflow order:
**conventions → build → deploy → on-device test**.

## Generic skills

The workspace also bundles agent-style skills for cross-cutting
documentation and tooling work; use them only when explicitly relevant
to the request, not for routine ROS 2 work:

- `architecture-blueprint-generator` — full architectural docs.
- `draw-io-diagram-generator`, `excalidraw-diagram-generator`,
  `plantuml-ascii` — diagram generation.
- `git-commit` — conventional commit composition.

## General rules

- Prefer existing workspace tasks (`run_task`), launch configurations,
  and scripts under `.vscode/` over ad hoc shell commands.
- Do not suggest generic ROS 2 workflows when this repository already
  defines a workspace-specific workflow.
- Never invent target-board credentials, IPs, or paths — read from
  `.vscode/settings.json` (see `arm64-deploy-debug` and
  `arm64-target-autonomous-test`).
- Treat the board as shared lab hardware: surface intent before any
  mutation, capture state before changes, restore after.
