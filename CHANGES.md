# CHANGES

## Version 1.0.0

Initial public release of the Azure Subscription Vending solution.

### Added

- Azure DevOps pipeline for end-to-end subscription vending workflow.
- Input validation, subscription preparation, bootstrap deployment, RBAC assignment, and final move stages.
- Optional Azure DevOps service connection manifest generation.
- Bootstrap infrastructure template using Bicep and Azure Verified Modules (AVM).
- Automation script for validation, deployment, RBAC, service connection manifest, and verification steps.
- Project documentation in English and Polish.

### Updated

- Pipeline and documentation aligned to the current bootstrap template path (`bicep/bootstrap.bicep`).
- Parameter comments added to the pipeline for clarity.

