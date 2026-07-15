# Security Policy

## Supported Versions

We actively maintain and support the core infrastructure versions deployed in this blueprint:

| Version | Supported |
| --- | --- |
| 1.30.x | :white_check_mark: |
| < 1.30 | :x: |

---

## Reporting a Vulnerability

We take the security of our infrastructure configurations seriously. If you find a security vulnerability (such as exposed credentials or incorrect policy profiles):

1.  Do **not** open a public issue.
2.  Report the issue directly to the maintainer via email.
3.  We will investigate, resolve, and publish a patch.

---

## Security Baselines Enforced
This repository enforces strict security guidelines at the architecture layer:
*   **Private Compute Subnets:** All compute worker nodes are scheduled inside private subnets, blocking public ingress.
*   **Credential Management:** Static AWS keys are prohibited. The platform relies exclusively on EKS Pod Identity.
*   **KMS Encryption:** KMS envelope encryption handles secrets management.
