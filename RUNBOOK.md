# Runbook — IBM Cloud Enterprise Centralized Logging

Step-by-step guide to deploy the centralized logging configuration using IBM Cloud Schematics.

---

## Overview

Two Schematics workspaces must be deployed **in order**:

```
Step 1 — central/    (Logging Account)
         Creates S2S Sender authorizations for every child account.

Step 2 — child/      (each child account, one workspace per account)
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
| **Child account primary region** | Region where workloads run (e.g. `us-south`) |

Make sure you are logged in to the IBM Cloud CLI:

```bash
ibmcloud login --sso
ibmcloud target -g <resource-group>
```

---

## Step 1 — Deploy the `central/` workspace

This workspace runs in the **centralized Logging Account**. It auto-discovers all enterprise child accounts and creates the required cross-account IAM S2S Sender authorizations.

### 1.1 — Switch to the Logging Account

```bash
ibmcloud target -c <CENTRAL_LOGGING_ACCOUNT_ID>
```

### 1.2 — Create the Schematics workspace

```bash
ibmcloud schematics workspace new --file - <<'EOF'
{
  "name": "central-logging-authorizations",
  "type": ["terraform_v1.5"],
  "location": "us-south",
  "description": "Creates cross-account S2S Sender authorizations for logs-router and atracker in all enterprise child accounts.",
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
        "name": "excluded_account_ids",
        "value": "[\"REPLACE_WITH_MANAGEMENT_ACCOUNT_ID\",\"REPLACE_WITH_CENTRAL_LOGGING_ACCOUNT_ID\"]"
      }
    ]
  }]
}
EOF
```

> Note the **workspace ID** returned (format: `us-south.workspace.xxxxx`).

### 1.3 — Run Plan and review

```bash
ibmcloud schematics plan --id <WORKSPACE_ID>

# Wait for the job to complete, then check the log
ibmcloud schematics logs --id <WORKSPACE_ID> --act-id <ACTIVITY_ID>
```

In the plan output, look for the `discovered_child_accounts` output and confirm **all expected child accounts** are listed.

### 1.4 — Apply

```bash
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

Wait for `Activity status: COMPLETED` before moving to Step 2.

---

## Step 2 — Deploy one `child/` workspace per child account

Repeat this step for **every child account**. Each workspace is fully independent with its own Terraform state.

### 2.1 — Switch to the child account

```bash
ibmcloud target -c <CHILD_ACCOUNT_ID>
```

### 2.2 — Create the Schematics workspace

Replace the variable values with the actual values for this specific child account.

```bash
ibmcloud schematics workspace new --file - <<'EOF'
{
  "name": "child-logging-REPLACE_WITH_NAME_PREFIX",
  "type": ["terraform_v1.5"],
  "location": "us-south",
  "description": "Deploys Logs Routing V3 and Activity Tracker enterprise-managed routes for this child account.",
  "template_repo": {
    "url": "https://github.com/alvcapai/atracker-config-ibmcloud",
    "branch": "main"
  },
  "template_data": [{
    "folder": "terraform/child",
    "type": "terraform_v1.5",
    "variablestore": [
      {
        "name": "ibmcloud_region",
        "value": "us-south"
      },
      {
        "name": "central_logs_crn",
        "value": "REPLACE_WITH_CENTRAL_LOGS_CRN",
        "secure": true
      },
      {
        "name": "logs_router_metadata_region",
        "value": "us-south"
      },
      {
        "name": "atracker_target_region",
        "value": "us-south"
      },
      {
        "name": "name_prefix",
        "value": "REPLACE_WITH_NAME_PREFIX"
      }
    ]
  }]
}
EOF
```

### 2.3 — Run Plan and review carefully

```bash
ibmcloud schematics plan --id <WORKSPACE_ID>
ibmcloud schematics logs --id <WORKSPACE_ID> --act-id <ACTIVITY_ID>
```

> ⚠️ **Review `ibm_logs_router_settings` changes carefully** in existing accounts. This resource controls the primary metadata region — an unintended change can affect pre-existing Logs Routing configuration.

### 2.4 — Apply

```bash
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

---

## Step 3 — Validate

Run these checks **inside each child account** after apply completes.

### 3.1 — Control-plane checks

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

### 3.2 — Data-plane checks (central account)

1. Open the **IBM Cloud Logs dashboard** in the centralized Logging Account.
2. Search for the child account's CRN or a known resource name.
3. Confirm an **Activity Tracker audit event** from the child account is present.
4. Confirm a **platform log** from a supported IBM Cloud service in the child account is present.
5. Record the validation timestamp and child account ID in your rollout evidence.

---

## Step 4 — Repeat for remaining child accounts

Go back to **Step 2** and repeat for each additional child account, changing `name_prefix` and `ibmcloud_region` as appropriate per account.

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
| `excluded_account_ids` | `["abc123","def456"]` | No |

### `child/` workspace

| Variable | Example value | Sensitive |
|---|---|---|
| `ibmcloud_region` | `us-south` | No |
| `central_logs_crn` | `crn:v1:bluemix:public:logs:...` | **Yes** |
| `logs_router_metadata_region` | `us-south` | No |
| `atracker_target_region` | `us-south` | No |
| `name_prefix` | `prod-us-south` | No |

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
```
