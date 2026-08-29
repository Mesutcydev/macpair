# Open-source program readiness

This checklist keeps Vamp ready for infrastructure, security, tooling,
and maintainer-support programs without overstating the project's maturity.
Program rules change; verify the linked requirements immediately before applying.

## Evidence already in the repository

- OSI-approved Apache-2.0 license and complete third-party notices
- public build and test instructions
- DCO-based contribution process and Code of Conduct
- named maintainers, governance, support, and security policies
- dependency lock files and automated dependency review
- macOS CI, CodeQL, OpenSSF Scorecard, and hardened-runner workflows
- release tooling for checksums, source-commit manifests, SBOMs, and staged
  website artifacts
- an agent contract, machine-readable manifest, and `llms.txt`

## Evidence to accumulate after launch

Keep a short application packet containing:

- canonical repository and website URLs;
- release cadence and changelog links;
- contributor, issue, download, and usage trends without collecting product
  telemetry;
- examples of resolved community issues and reviewed pull requests;
- current CI/security status and an OpenSSF badge link;
- a one-paragraph explanation of community benefit;
- an honest funding, employment, and commercial-support statement; and
- the specific resource requested and how it will improve the project.

Do not inflate stars, downloads, contributor counts, security posture, or project
age. Keep dated screenshots or links for claims that an application form cannot
verify automatically.

## Programs and milestones

### OpenSSF Best Practices

Create a project entry at
<https://www.bestpractices.dev/> after the public repository exists. The project is
prepared for the baseline questionnaire, but the maintainer must answer operational
questions that cannot be proven by repository files alone.

### MacStadium FOSS

Program information: <https://www.macstadium.com/company/opensource>

Wait until the project has at least three months of public development and regular
releases. Before applying, confirm that the maintainer and funding model meet the
current unpaid-contributor, commercial-funding, and free-software requirements.
The application should request macOS CI capacity and cite the universal host/client
test workload.

### JetBrains open-source support

Program information: <https://www.jetbrains.com/community/opensource/>

The established-project program is impact-based. Apply only after the public project
shows sustained maintenance and meaningful developer-community use. Individual
non-commercial open-source work may qualify under JetBrains' separate
non-commercial terms without implying project sponsorship.

### GitHub Sponsors

Program information:
<https://docs.github.com/en/sponsors/getting-started-with-github-sponsors/about-github-sponsors>

The maintainer must personally complete identity, region, tax, payout, and
two-factor-authentication requirements. Add `.github/FUNDING.yml` only after a real
sponsor profile is approved; never publish a placeholder funding destination.

### Security funding

Monitor <https://github.com/open-source/github-secure-open-source-fund> and other
maintainer-security programs after the project has real users and a documented
security roadmap. Availability and cohort rules change, so an old application link
must not be treated as proof that applications are open.

## Repository settings to capture after publication

- default-branch rules and required CI checks;
- private vulnerability reporting;
- secret scanning and push protection, when available;
- Dependabot alerts and security updates;
- Discussions or another documented community channel; and
- release and domain access held by at least two maintainers when the project grows.

These settings live on the hosting service and cannot be established or audited
from a local source tree alone.
