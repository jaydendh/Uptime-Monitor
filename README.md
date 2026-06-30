# Azure Website Uptime Monitor

An automated website monitoring system built on Azure — checks a target site every five minutes for availability, response time, and content validity, and alerts the owner via email and SMS within seconds of a failure. Infrastructure is provisioned entirely with Terraform and deployed through a two-stage GitHub Actions CI/CD pipeline authenticated with OIDC (no stored secrets).

---

![Repo file tree](screenshots/01-repo-file-tree.png)

## Table of Contents

- [Architecture](#architecture)
- [What It Does](#what-it-does)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [How the Environment Works](#how-the-environment-works)
- [Screenshot Guide](#screenshot-guide)
- [CI/CD Pipeline](#cicd-pipeline)
- [Setting Up OIDC Authentication](#setting-up-oidc-authentication)
- [GitHub Secrets](#github-secrets)
- [Getting Started](#getting-started)
- [Verifying the Monitor](#verifying-the-monitor)
- [Dashboard & Alerting](#dashboard--alerting)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)
- [Key Learnings](#key-learnings)

---

## Architecture

```
![Architecture](./screenshots/
```

![Resource group overview](screenshots/07-rg-resource-group.png)

---

## What It Does

Every five minutes, an Azure Function:

1. **Checks reachability** — sends an HTTP GET to the target URL with a 10-second timeout
2. **Checks response time** — flags anything over 5,000 ms as `SLOW`
3. **Checks content validity** — looks for error indicators in the response body
4. **Writes the result** to Azure Table Storage with a timestamp, status (`PASS` / `SLOW` / `FAIL`), and response time
5. **Fires an alert** via email and SMS within seconds of a failure, routed through Application Insights → Log Analytics → Azure Monitor → Action Group

---

## Tech Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform (azurerm ~> 3.0) |
| Compute | Azure Functions — Consumption Plan (Python 3.10) |
| Storage | Azure Table Storage |
| Monitoring | Application Insights + Log Analytics |
| Alerting | Azure Monitor Scheduled Query Alert + Action Group |
| CI/CD | GitHub Actions, OIDC federated authentication |

---

## Project Structure

```
uptime-monitor/
├── .github/
│   └── workflows/
│       ├── ci.yml             # runs on every PR targeting main — validate only
│       └── cicd.yml           # runs on push/merge to main — validate + deploy
├── function_app/
│   ├── check_website.py       # monitoring logic
│   ├── function.json          # timer trigger binding (CRON: every 5 min)
│   └── requirements.txt
├── main.tf
├── variables.tf
├── outputs.tf
├── terraform.tfvars           # local values — gitignored, never committed
├── .gitignore
└── README.md
```

---

## How the Environment Works

There are three distinct "environments" this project touches, and it's worth understanding how each one is wired to the others — that's what actually makes the automation work.

### 1. Local development environment

This is your own machine — where you write and test Terraform and Python before anything reaches Azure.

- **Terraform CLI** reads `main.tf`, `variables.tf`, and `terraform.tfvars` from your working directory and talks to Azure's Resource Manager API to plan/apply changes.
- **Azure CLI** (`az login`) is how *you* personally authenticate when running Terraform by hand — this is separate from how the *pipeline* authenticates (OIDC, no `az login` involved there).
- **Python + pip** are used to test `check_website.py` locally and to install the dependencies listed in `requirements.txt` before packaging.
- `terraform.tfvars` lives only on your machine — it's listed in `.gitignore` and is never pushed to GitHub, because it contains real values (your email, phone number, target URL).

Nothing here is shared automatically with GitHub or Azure — every value has to be deliberately passed forward, either by you typing it into a CLI flag or by a GitHub secret being injected into the pipeline.

### 2. The GitHub Actions runtime environment

Each job in `ci.yml` and `cicd.yml` spins up a **brand-new, disposable Ubuntu virtual machine** — `runs-on: ubuntu-latest`. This matters more than it sounds like it should:

- That VM starts with *nothing* on it. No repo, no Terraform binary, no Azure CLI session.
- Every job re-does `actions/checkout@v4` (pull the repo), `azure/login@v2` (authenticate), and `hashicorp/setup-terraform@v3` (install Terraform) — from scratch, every single run.
- `test_terraform` and `build_terraform` in `cicd.yml` are **two separate VMs**, even though they're in the same file. They don't share a filesystem, a Terraform state cache, or an Azure login session — that's why `build_terraform` has to log in to Azure and run `init` again, even though `test_terraform` already did it seconds earlier.
- **GitHub Secrets** (`AZURE_CLIENT_ID`, etc.) are injected as environment variables only inside this VM, only for the duration of the job, and only because the workflow file explicitly references them with `${{ secrets.NAME }}`. They never touch your local machine or get written to disk in plain text.
- The **OIDC token** that authenticates this VM to Azure is generated fresh by GitHub for that specific job run, lives for a few minutes, and is tied to a specific subject claim (which repo, which branch or PR, which workflow) — covered in detail in [Setting Up OIDC Authentication](#setting-up-oidc-authentication).

When the job ends, the VM is destroyed completely. Nothing persists between runs except what you've explicitly stored elsewhere (like Terraform state, covered next).

### 3. The Azure runtime environment

This is where the actual application lives once deployed — and it has its own internal wiring, separate from GitHub entirely.

- **Terraform state** — by default, Terraform tracks what it's created in a local `terraform.tfstate` file. Because each pipeline run is a fresh, disposable VM, there's no "local" to persist that file to between runs. *(If you haven't already, this is the point where most projects move to a remote backend — like Terraform state stored in an Azure Storage container — so `cicd.yml` can find and update the same state every time, rather than starting blind.)*
- **App settings** (`app_settings` block in `main.tf`) are how the Function App receives configuration *at runtime*, after deployment. `TARGET_URL`, `AzureWebJobsStorage`, and the Application Insights keys are all injected here by Terraform and read inside `check_website.py` via `os.environ[...]`. This is why the Python code never hardcodes a URL or a connection string — it asks the environment for it, and Terraform is what populates that environment.
- **The timer trigger** (`function.json`) is evaluated by the Azure Functions runtime itself, not by anything in your pipeline. Once deployed, the function runs on its own schedule indefinitely — the pipeline's job ends the moment deployment succeeds; it has no ongoing role in keeping the function running.
- **Application Insights and Log Analytics** form a separate, passive observation layer — they don't affect how the function runs, they just continuously capture what it does, which is what the Monitor Alert Rule reads from to decide when to fire.

### How the three connect

```
Your machine  →  git push  →  GitHub Actions VM  →  OIDC token  →  Azure Resource Manager
   (write code)      (trigger)      (build & test)      (auth)          (provision/update)
                                                                              │
                                                                              ▼
                                                                    Function App reads
                                                                    app_settings at runtime
                                                                    → runs independently
                                                                      on its own schedule
```

The key habit this project builds: nothing is "shared" between these three environments by default. Every value, every credential, every piece of state has to be deliberately passed across the boundary — a secret, an app setting, a token — or it simply doesn't exist on the other side.

---

## Screenshot Guide

All screenshots live in a single `screenshots/` folder at the repo root, referenced from this README using relative markdown image links. Using a consistent naming convention means each filename tells you exactly where it belongs without opening it.

**Naming convention:** `NN-section-what-it-shows.png`

- `NN` — two-digit number controlling the order they're taken/referenced (01, 02, 03...)
- `section` — short tag for which README section it illustrates (`repo`, `actions`, `oidc`, `secrets`, `rg`, `func`, `monitor`, `alerts`)
- `what-it-shows` — a few words describing the actual content

```
screenshots/
├── 01-repo-file-tree.png
├── 02-actions-ci-run.png
├── 03-actions-cicd-run.png
├── 04-oidc-federated-credentials.png
├── 05-oidc-error-log.png
├── 06-secrets-list.png
├── 07-rg-resource-group.png
├── 08-func-functions-list.png
├── 09-func-monitor-invocations.png
├── 10-table-query-results.png
├── 11-appinsights-live-metrics.png
├── 12-alerts-alert-rule.png
└── 13-alerts-action-group.png
```

```cmd
git add screenshots/
git commit -m "docs: add architecture and pipeline screenshots"
git push
```

Once they're pushed, every `<!-- SCREENSHOT -->` placeholder throughout this README is already wired to the matching filename — no further edits needed.

---

This project uses **two separate workflow files**, each with a distinct trigger and purpose.

### `ci.yml` — validation only

| Trigger | `pull_request` targeting `main` |
|---|---|
| Job | `test_terraform` |
| Steps | Checkout → Azure login (OIDC) → Setup Terraform → `init` → `validate` → `fmt -check` → `plan` |

This runs every time a PR is opened against `main`. It never touches live infrastructure — `plan` is a dry run.

![CI run on a pull request](screenshots/02-actions-ci-run.png)

### `cicd.yml` — validate and deploy

| Trigger | `push` to `main` (includes merged PRs) |
|---|---|
| Jobs | `test_terraform` → `build_terraform` (`needs: test_terraform`) |
| `build_terraform` steps | Checkout → Azure login (OIDC) → Setup Terraform → `init` → `validate` → `fmt -check` → `plan` → `apply -auto-approve` |

`build_terraform` only starts if `test_terraform` succeeds — that dependency is declared with `needs:`. This means a broken `plan` or formatting issue blocks the deploy automatically, before `apply` ever runs.

![CI/CD run after merge to main](screenshots/03-actions-cicd-run.png)

### Why two files instead of one

`pull_request` and `push` events generate **different OIDC subject claims** from GitHub's token issuer. Keeping the two triggers in separate files made it straightforward to scope a federated credential to each one individually (see below), rather than juggling conditional logic inside a single workflow.

---

## Setting Up OIDC Authentication

No client secrets are stored anywhere in this pipeline. Azure trusts GitHub's OIDC token directly, validated against **federated credentials** configured on the Service Principal's App Registration.

Two federated credentials are required — one per trigger type, because each produces a different subject claim:

| Credential | Entity Type | Subject Claim Generated |
|---|---|---|
| Branch — `main` | Branch | `repo:<org>/<repo>:ref:refs/heads/main` |
| Pull request | Pull request | `repo:<org>/<repo>:pull_request` |

**To add each one:**
Azure Portal → **App Registrations** → your app → **Certificates & secrets** → **Federated credentials** → **Add credential** → scenario: *GitHub Actions deploying Azure resources* → fill in Organization, Repository, and the correct Entity type for each row above.

![Federated credentials configured for branch and pull_request](screenshots/04-oidc-federated-credentials.png)

> **Lesson learned the hard way:** a federated credential scoped only to the `main` branch will reject tokens from `pull_request`-triggered runs — the subject claims don't match. Azure isn't checking "is this the right app," it's checking "does this exact subject string have an entry." Each distinct trigger context needs its own entry.

![OIDC federated identity mismatch error, since resolved](screenshots/05-oidc-error-log.png)

---

## GitHub Secrets

**Settings → Secrets and variables → Actions:**

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | App Registration client ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

![GitHub Actions secrets configured](screenshots/06-secrets-list.png)

---

## Getting Started

```bash
git clone https://github.com/<your-username>/Uptime-Monitor.git
cd Uptime-Monitor
```

Create `terraform.tfvars` locally (this file is gitignored and never committed):

```hcl
yourname    = "yourname"
location    = "East US"
target_url  = "https://your-site.com"
alert_email = "you@example.com"
alert_phone = "+14045550100"
```

**Working with the pipeline:**

```bash
# feature work — triggers ci.yml only
git checkout -b feature/my-change
# make changes
git push origin feature/my-change
# open a PR targeting main → ci.yml runs

# after merge → cicd.yml runs automatically, applying to Azure
```

---

## Verifying the Monitor

First confirm the actual function code deployed into the container Terraform built — not just the empty App Service shell:

**Function App → Functions** — `check_website` should be listed.

![Functions list showing check_website deployed](screenshots/08-func-functions-list.png)

Then confirm it's executing on schedule:

```bash
az storage entity query \
  --account-name stuptime<yourname> \
  --table-name uptimechecks \
  --auth-mode login \
  --output table
```

![Table storage query results showing PASS rows](screenshots/10-table-query-results.png)

In the portal: **Function App → check_website → Monitor** — confirm invocations every five minutes.

![Function App Monitor tab showing 5-minute invocations](screenshots/09-func-monitor-invocations.png)

---

## Dashboard & Alerting

**Application Insights → Live Metrics** — real-time invocation stream.

![Application Insights Live Metrics](screenshots/11-appinsights-live-metrics.png)

**Azure Monitor → Alert Rules** — confirm `alert-site-down-[yourname]` is Enabled.

![Alert rule enabled](screenshots/12-alerts-alert-rule.png)

**Azure Monitor → Action Groups** — confirm both email and SMS receivers are configured.

![Action group with email and SMS receivers](screenshots/13-alerts-action-group.png)

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---|---|---|
| `No matching federated identity record found` | Federated credential doesn't match the event's subject claim | Add a separate federated credential per trigger type (branch vs. pull_request) |
| `File ... exceeds GitHub's file size limit` on push | `.terraform/` provider binaries committed | `git rm -r --cached .terraform/`, add `.gitignore`, and if already pushed, reset/rewrite history before re-pushing |
| `terraform fmt -check` fails in CI | Files not formatted to Terraform's style convention | Run `terraform fmt` locally (no `-check`) and commit the result |
| `Unsupported argument` on `azurerm_monitor_scheduled_query_rules_alert_v2` | Resource schema uses different argument names than expected (e.g. `auto_mitigate` vs `auto_mitigation_enabled`, `action_group_id` vs an `action { action_groups = [...] }` block) | Match the provider's actual schema — check the Terraform Registry docs for the resource |
| `401 Unauthorized` / `Operation cannot be completed without additional quota` on `terraform apply` | Subscription has 0 quota for compute in the target region | Request a quota increase under Portal → Quotas, or deploy to a different region with available quota |
| SMS not delivered | Phone number format incorrect | Use E.164 format: `+1` followed by 10 digits, no spaces or dashes |

---

## Teardown

```bash
terraform destroy
```

---

## Key Learnings

- **OIDC federated credentials are scoped to the exact subject claim a token presents — not to "the repo" in general.** A `pull_request` event and a `push` to `main` produce different subject strings, so each needs its own federated credential entry on the App Registration.

- **Never commit `.terraform/`.** It contains provider binaries that can exceed GitHub's 100MB file limit, and once committed, removing it from the latest commit isn't enough — it has to be purged from history (via `git filter-repo` or a hard reset to a clean commit) before a push will succeed.

- **`terraform fmt -check` exits non-zero deliberately** — it's a guard rail in CI, not a fixer. Run plain `terraform fmt` locally to actually rewrite the files, then commit the formatted version.

- **Resource argument names don't always match intuition.** `azurerm_monitor_scheduled_query_rules_alert_v2` uses `auto_mitigation_enabled` and an `action { action_groups = [...] }` block rather than the more obvious-sounding names — always check the provider's Registry docs against the actual error rather than guessing.

- **A 401 quota error during `apply` is an Azure subscription limit, not a Terraform or pipeline bug.** New or low-usage subscriptions often start with 0 compute quota in a given region until an increase is requested.

- **Splitting CI and CD into two workflow files** made it straightforward to give the PR-validation job a tighter, narrower trigger than the deploy job — and to scope OIDC trust separately for each.

---

*Infrastructure provisioned with Terraform · Deployed via GitHub Actions OIDC · Built on Azure*
