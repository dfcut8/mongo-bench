# Project guidance

## Purpose

Build a Go service that manages libraries through an API. It connects to MongoDB hosted in the cloud, most likely a managed service on Azure. The service has no UI.

## Scope

- Create, read, update, and delete libraries, books, and members.
- Each book belongs to a library.
- Members can borrow and return books.

See [docs/architecture.md](docs/architecture.md) for the proposed architecture, API, data model, and initial assumptions. Treat open decisions there as decisions to revisit, not implemented behavior.

## Implementation guidance

Keep HTTP handling, business rules, and MongoDB persistence separate. Pass configuration and dependencies explicitly, use Go contexts for request and database operations, and keep credentials out of source control. Preserve the borrowing invariants when changing the data model or persistence logic. Add focused tests for business rules and integration tests for database behavior as implementation is introduced.

## Pull requests

- Use the GitHub CLI (gh) to open pull requests. You may open a pull request when a task is complete.
- When the user says lgtm about a pull request, that authorizes merging it and deleting its branch.
