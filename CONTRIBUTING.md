# Contributing to AI Infrastructure on Amazon EKS

We welcome contributions to this blueprint! To maintain a production-grade codebase, please adhere to the following guidelines:

---

## 1. Development Workflow

1.  **Fork the Repository:** Create a personal fork of the repository.
2.  **Create a Feature Branch:** Build changes on top of a dedicated branch (e.g. `feature/dynamic-mig-support`).
3.  **Local Validations:** Before submitting any Pull Request, format and validate your changes using the local Makefile automation:
    ```bash
    make fmt
    make validate
    ```
4.  **Documentation Guidelines:** If you are adding a new feature or infrastructure component, keep explanatory comments inside the `.tf` code blocks (do not strip comments during refactoring) and update the corresponding architectural documentation in `/docs`.

---

## 2. Commit Message Guidelines

We enforce clean, descriptive commit messages. Please format commit subjects as:
```text
<type>(<scope>): <subject>
```
*Example:* `feat(karpenter): add support for g6 instance families`

---

## 3. Pull Request Process

1.  Submit your Pull Request against the main branch.
2.  Ensure that all local Terraform validations pass.
3.  Prerequisites: Pull Requests will be reviewed for documentation completeness and compliance with security constraints (e.g. placing compute resources inside private subnets).
