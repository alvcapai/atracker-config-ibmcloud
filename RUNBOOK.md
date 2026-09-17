# Runbook — IBM Cloud Enterprise Centralized Logging

Step-by-step guide to deploy the centralized logging configuration using IBM Cloud Schematics.

---

## Overview

Three steps must be executed **in order**:

```
Step 1 — central/    (Logging Account)
         Creates S2S Sender authorizations for every child account AND
         emits a ready-to-use Schematics workspace payload per child.

Step 2 — Automated   (still in Logging Account)
         create-child-workspaces.sh reads the central output and creates
         all child Schematics workspaces automatically — no manual JSON.

Step 3 — child/      (each child workspace is applied in its own account)
         Deploys Logs Routing V3 + Activity Tracker enterprise-managed routes.
```

> ⚠️ The `central/` workspace **must be applied first**. Child routes will fail without the S2S authorizations.

---

## Prerequisites

Before starting, collect the following values:

| Value | How to find it |
|-------|---------------|
| **Enterprise name** | `ibmcloud enterprise show` → `Name` field |
| **Management account ID** | `ibmcloud enterprise show` → `Primary account ID` |
| **Central Logging Account ID** | `ibmcloud account show` (logged into the Logging Account) |
| **Central IBM Cloud Logs instance GUID** | `ibmcloud resource service-instance <name> --output json \| jq -r '.[0].guid'` |
| **Central IBM Cloud Logs CRN** | `ibmcloud resource service-instance <name> --output json \| jq -r '.[0].crn'` |
| **Child accounts' primary region** | Region where workloads run (e.g. `us-south`) |

Make sure you are logged in to the IBM Cloud CLI **as the central Logging Account**:

```bash
ibmcloud login --sso
ibmcloud target -c <CENTRAL_LOGGING_ACCOUNT_ID>
ibmcloud target -g <resource-group>
```

---

## Step 1 — Deploy the `central/` workspace

This workspace runs in the **centralized Logging Account**. It auto-discovers all enterprise child accounts, creates the required cross-account IAM S2S Sender authorizations, and **emits a fully populated Schematics workspace payload for every child account** via the `child_workspace_payloads` output.

### 1.1 — Create the Schematics workspace

```bash
ibmcloud schematics workspace new --file - <<'EOF'
{
  "name": "central-logging-authorizations",
  "type": ["terraform_v1.5"],
  "location": "us-south",
  "description": "Creates cross-account S2S Sender authorizations and generates child workspace payloads for all enterprise child accounts.",
  "template_repo": {
    "url": "https://github.com/alvcapai/atracker-config-ibmcloud",
    "branch": "main"
  },
  "template_data": [{
    "folder": "terraform/central",
    "type": "terraform_v1.5",
    "variablestore": [
      {
        "name": "ibmcloud_region",
        "value": "us-south"
      },
      {
        "name": "enterprise_name",
        "value": "REPLACE_WITH_ENTERPRISE_NAME"
      },
      {
        "name": "central_logs_instance_id",
        "value": "REPLACE_WITH_CENTRAL_LOGS_INSTANCE_GUID",
        "secure": true
      },
      {
        "name": "central_logs_crn",
        "value": "REPLACE_WITH_CENTRAL_LOGS_CRN",
        "secure": true
      },
      {
        "name": "child_region",
        "value": "us-south"
      },
      {
        "name": "excluded_account_ids",
        "value": "[\"REPLACE_WITH_MANAGEMENT_ACCOUNT_ID\",\"REPLACE_WITH_CENTRAL_LOGGING_ACCOUNT_ID\"]"
      }
    ]
  }]
}
EOF
```

> Note the **workspace ID** returned (format: `us-south.workspace.xxxxx`).

### 1.2 — Run Plan and review

```bash
ibmcloud schematics plan --id <WORKSPACE_ID>

# Wait for the job to complete, then check the log
ibmcloud schematics logs --id <WORKSPACE_ID> --act-id <ACTIVITY_ID>
```

In the plan output, look for the `discovered_child_accounts` output and confirm **all expected child accounts** are listed.

### 1.3 — Apply

```bash
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

Wait for `Activity status: COMPLETED` before moving to Step 2.

---

## Step 2 — Auto-create all child workspaces

Run the automation script from the **central Logging Account** context. It reads the `child_workspace_payloads` output and creates one Schematics workspace per discovered child account — no manual JSON editing required.

```bash
./scripts/create-child-workspaces.sh <CENTRAL_WORKSPACE_ID>
```

The script will:
1. Fetch `child_workspace_payloads` from the central workspace outputs.
2. Skip any child workspace whose name already exists (safe to re-run).
3. Print a summary of created vs skipped workspaces.

> The script creates workspaces but does **not** apply them — review plans first.

---

## Step 3 — Plan and apply all child workspaces

### 3.1 — Plan each child workspace

```bash
# List all child workspace IDs created by the script
ibmcloud schematics workspace list --output json \
  | jq -r '.workspaces[] | select(.name | startswith("child-logging-")) | .id'

# Plan a specific child workspace
ibmcloud schematics plan --id <CHILD_WORKSPACE_ID>
ibmcloud schematics logs --id <CHILD_WORKSPACE_ID> --act-id <ACTIVITY_ID>
```

> ⚠️ **Review `ibm_logs_router_settings` changes carefully** in existing accounts. This resource controls the primary metadata region — an unintended change can affect pre-existing Logs Routing configuration.

### 3.2 — Apply

```bash
ibmcloud schematics apply --id <CHILD_WORKSPACE_ID> --force
```

Repeat for each child workspace. Each one is fully independent with its own Terraform state.

---

## Step 4 — Validate

Run these checks **inside each child account** after apply completes.

### 4.1 — Control-plane checks

```bash
# Activity Tracker — confirm enterprise-managed target and wildcard route exist
ibmcloud atracker target ls
ibmcloud atracker route ls

# Logs Routing V3 — confirm enterprise-managed target and route exist
ibmcloud logs-router target list
ibmcloud logs-router route list
```

Expected results:
- Activity Tracker target points to the central IBM Cloud Logs CRN
- Activity Tracker route has `locations = ["*"]`
- Logs Routing target has `managed_by = enterprise`
- Logs Routing route has `managed_by = enterprise`

### 4.2 — Data-plane checks (central account)

1. Open the **IBM Cloud Logs dashboard** in the centralized Logging Account.
2. Search for the child account's CRN or a known resource name.
3. Confirm an **Activity Tracker audit event** from the child account is present.
4. Confirm a **platform log** from a supported IBM Cloud service in the child account is present.
5. Record the validation timestamp and child account ID in your rollout evidence.

---

## Step 5 — Apply IAM guardrails (after all accounts validated)

Once data-plane validation is confirmed for all child accounts, enforce the IAM Action Control guardrail to prevent tampering with the enterprise-managed routes.

Protect the following actions at minimum:

| Service | Actions to protect |
|---|---|
| Logs Routing | `logs-router.route.update`, `logs-router.route.delete`, `logs-router.target.update`, `logs-router.target.delete` |
| Activity Tracker | `atracker.route.update`, `atracker.route.delete`, `atracker.target.update`, `atracker.target.delete`, `atracker.setting.update` |

See [Enterprise IAM Action Control templates](https://cloud.ibm.com/docs/enterprise-management?topic=enterprise-management-act-template-create).

---

## Quick reference — variable cheat sheet

### `central/` workspace

| Variable | Example value | Sensitive |
|---|---|---|
| `ibmcloud_region` | `us-south` | No |
| `enterprise_name` | `My Enterprise` | No |
| `central_logs_instance_id` | `a1b2c3d4-...` (GUID) | **Yes** |
| `central_logs_crn` | `crn:v1:bluemix:public:logs:...` | **Yes** |
| `child_region` | `us-south` | No |
| `github_repo_url` | `https://github.com/alvcapai/atracker-config-ibmcloud` | No |
| `github_branch` | `main` | No |
| `excluded_account_ids` | `["mgmt-id","logging-id"]` | No |

> `child_region`, `github_repo_url`, and `github_branch` have sensible defaults and only need to be specified if they differ from the defaults.

### `child/` workspace (generated automatically — no manual editing needed)

| Variable | Set by | Sensitive |
|---|---|---|
| `ibmcloud_region` | `child_region` from central | No |
| `central_logs_crn` | `central_logs_crn` from central | **Yes** |
| `logs_router_metadata_region` | `child_region` from central | No |
| `atracker_target_region` | `child_region` from central | No |
| `name_prefix` | derived from child account name | No |

---

## Useful commands

```bash
# List all Schematics workspaces
ibmcloud schematics workspace list

# Check workspace state
ibmcloud schematics workspace get --id <WORKSPACE_ID>

# View latest logs
ibmcloud schematics logs --id <WORKSPACE_ID> --act-id <ACTIVITY_ID>

# Destroy a workspace (if rollback needed)
ibmcloud schematics destroy --id <WORKSPACE_ID> --force
ibmcloud schematics workspace delete --id <WORKSPACE_ID> --force

# List all child workspace IDs
ibmcloud schematics workspace list --output json \
  | jq -r '.workspaces[] | select(.name | startswith("child-logging-")) | [.name, .id] | @tsv'
```
