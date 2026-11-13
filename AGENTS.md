# Project guidance

## Purpose

Build a Go service that manages libraries through an API. The service and self-hosted MongoDB run on Azure Kubernetes Service (AKS), with images in Azure Container Registry (ACR). Dev has a dedicated cluster; prod will use a separate cluster later. The service has no UI.

## Scope

- Create, read, update, and delete libraries, books, and members.
- Each book belongs to a library.
- Members can borrow and return books.

See [docs/architecture.md](docs/architecture.md) for the proposed architecture, API, data model, and initial assumptions. Treat open decisions there as decisions to revisit, not implemented behavior.

## Repository structure

This repository owns one service. Keep the Go module at the repository root, with executable entry points under `cmd/` and implementation packages under `internal/`; do not introduce a top-level `src/` directory for now. Keep service documentation under `docs/` and infrastructure code under `infra/`. Choose package boundaries as the implementation develops rather than creating a fixed hierarchy in advance.

Treat `infra/` as the infrastructure monorepo root. Its sibling Terraform projects are `core` (Azure compute, registry, identities, and persistent disk), `db` (MongoDB, database credentials, and persistent volume bindings), and `app` (application namespace, connection Secret, and service deployment). Each project has its own Terraform root, providers, lock file, and state. Apply core, then db, then app. Routine app releases must not plan or apply database resources.

## Implementation guidance

Keep HTTP handling, business rules, and MongoDB persistence separate. Pass configuration and dependencies explicitly, use Go contexts for request and database operations, and keep credentials out of source control. Preserve the borrowing invariants when changing the data model or persistence logic. Add focused tests for business rules and integration tests for database behavior as implementation is introduced.

## Pull requests

- Use the GitHub CLI (gh) to open pull requests. You may open a pull request when a task is complete.
- When the user says lgtm about a pull request, that authorizes merging it and deleting its branch.
