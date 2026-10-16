# ci

Reusable GitHub Actions workflows for the projects of sascha-gruesshaber. The standard
and the interfaces are described in `README.md`. That README is the contract with the
projects: whatever it says must work exactly that way.

- The workflows live in `.github/workflows/` and use `on: workflow_call`.
- They are called with `@v1`. After a change has landed on `main`, a new `v1.x.y` tag is
  set and `v1` is moved to it. Incompatible changes only ship as `v2`.
- Every change hits all projects at once. So only add inputs, with a default value;
  never rename or remove them.
- This repository's CI checks the workflows with `actionlint`.
- This repository is public (see "Access" in the README). Never put secrets, internal
  addresses or project-specific values in it.
- Everything in this repository is written in English.
