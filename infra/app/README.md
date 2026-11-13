# Application

Independent Terraform project for the service namespace, database connection Secret, optional local image build/push, and service Deployment/Service. Contains no MongoDB workloads or volume resources.

Apply core and db first. This project reads their state outputs; it never plans or applies their resources. The application image is opt-in until a service Dockerfile exists. The app uses the `mongo-bench` database user, not the administrator account.

From `infra/`: `./Invoke-TerraformDeploy.ps1 -Env dev -Project app -Plan`, review the plan, then run the same command with `-Apply`. For a routine release, update the application tag/revision and plan/apply only this project. Relative local build contexts resolve from this directory; use `../..` for the service repository root.

See the [infrastructure guide](../README.md) for local releases.
