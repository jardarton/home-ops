# AGENTS.md

This is a GitOps repository for my home Kubernetes cluster.

- The cluster runs on Talos Linux.
- Flux is used for GitOps reconciliation.
- Changes should be made declaratively in Git.

## Public repository: documentation policy

- This repository is public. Commit only configuration, code, minimal maintenance
  comments, and the public-facing files explicitly allowed below; do not include
  private operational details.
- Put all documentation, notes, incident reports, diagnostic output, screenshots,
  and other informational artifacts in the gitignored root `docs/` directory.
  This includes READMEs and non-Markdown formats, except for these public files:
  - Root `README.md` and `cluster.jpg` are intentionally public; keep them tracked.
  - `AGENTS.md` stays tracked and limited to public-safe contributor instructions,
    never operational notes.
- Never force-add ignored documentation. Before committing, inspect the staged
  diff for private information, including household/device details, credentials,
  backup locations, and live infrastructure findings.
