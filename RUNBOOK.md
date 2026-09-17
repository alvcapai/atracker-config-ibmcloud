# Runbook — IBM Cloud Enterprise Centralized Logging

Step-by-step guide to deploy the centralized logging configuration using IBM Cloud Schematics.

---

## Overview

Two Schematics workspaces must be deployed **in order**:

```
Step 1 — central/    (account that owns the central IBM Cloud Logs instance)
         Lists the enterprise child accounts and creates one S2S Sender
         authorization per child account per source service
         (logs-router, atracker).

Step 2 — child/      (each child account, one workspace per account)
         Deploys Logs Routing V3 + Activity Tracker enterprise-managed routes.
```

> ⚠️ The `central/` workspace **must be applied first**. Child routes will fail without the S2S authorizations.

Cross-account service-to-service authorizations always live in the account that owns the **target** resource. So `central/` must run in the account that holds the central IBM Cloud Logs instance — never in a child account.

---

## Prerequisites

Before starting, collect the following values:

| Value | How to find it |
|-------|---------------|
| **Central IBM Cloud Logs CRN** | `ibmcloud resource service-instance <name> --output json \| jq -r '.[0].crn'` |
| **Enterprise name** (optional) | `ibmcloud enterprise show` → `Name` field |
| **Child account IDs** (layout B only) | `ibmcloud enterprise accounts --output JSON \| jq -r '.[].id'` — run from the enterprise account |
| **Child account primary region** | Region where workloads run (e.g. `us-south`) |

The CRN is the only identifier `central/` really needs: the instance GUID (the authorization target) and the account ID that owns it (auto-excluded from discovery) are both parsed out of it.

Make sure you are logged in to the IBM Cloud CLI:

```bash
ibmcloud login --sso
ibmcloud target -g <resource-group>
```

### Which account can list the child accounts?

`central/` calls the Enterprise Management **ListAccounts** API. That call only succeeds for an identity with enterprise access — in practice an identity in the **enterprise (management) account**. A plain child account gets nothing back. This gives two layouts:

| | **Layout A** — central Logs instance in the enterprise/management account | **Layout B** — central Logs instance in a dedicated logging account |
|---|---|---|
| Child account discovery | Automatic, every apply | Not possible from that account |
| What you set | `central_logs_crn` (+ optional `enterprise_name`) | `central_logs_crn` + `child_account_ids` |
| Keeping the list current | Nothing to do — re-apply picks up new accounts | Refresh `child_account_ids` and re-apply (see Step 1b) |

Both layouts use the same code. Supplying `child_account_ids` turns discovery off completely, so no enterprise API call is attempted.

### Permissions for the Schematics execution identity

| Workspace | Needs |
|---|---|
| `central/` | **Administrator** on IBM Cloud Logs (or on the specific central instance) in the account the workspace runs in — required to create cross-account authorizations against that instance. **Layout A only:** also enterprise-level access to list accounts (Enterprise Management service, Viewer or higher, assigned in the enterprise account). |
| `child/` | Permission to manage IBM Cloud Logs Routing and Activity Tracker Event Routing in the child account (Administrator on `logs-router` and `atracker`). |

---

## Step 1 — Deploy the `central/` workspace

This workspace runs in the account that owns the **central IBM Cloud Logs instance**. It lists the enterprise child accounts and creates one cross-account IAM S2S `Sender` authorization per child account per source service.

### 1.1 — Switch to that account

```bash
ibmcloud target -c <ACCOUNT_THAT_OWNS_THE_CENTRAL_LOGS_INSTANCE>
```

### 1.2 — Create the Schematics workspace

**Layout A — central Logs instance in the enterprise/management account.** Discovery does the rest; the management account and the central account exclude themselves.

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
      { "name": "ibmcloud_region",  "value": "us-south" },
      { "name": "central_logs_crn", "value": "crn:v1:bluemix:public:logs:us-south:a/ACCOUNT_ID:INSTANCE_GUID::" },
      { "name": "enterprise_name",  "value": "REPLACE_WITH_ENTERPRISE_NAME" }
    ]
  }]
}
EOF
```

**Layout B — central Logs instance in a dedicated logging account.** That account cannot call the enterprise API, so hand it the list. Generate it from the enterprise account first:

```bash
ibmcloud target -c <MANAGEMENT_ACCOUNT_ID>
ibmcloud enterprise accounts --output JSON \
  | jq -c '[.[] | select(.state == "ACTIVE") | .id]'
# → ["abc...","def...","ghi..."]
```

Then create the workspace in the logging account with that list as `child_account_ids`:

```bash
ibmcloud schematics workspace new --file - <<'EOF'
{
  "name": "central-logging-authorizations",
  "type": ["terraform_v1.5"],
  "location": "us-south",
  "template_repo": {
    "url": "https://github.com/alvcapai/atracker-config-ibmcloud",
    "branch": "main"
  },
  "template_data": [{
    "folder": "terraform/central",
    "type": "terraform_v1.5",
    "variablestore": [
      { "name": "ibmcloud_region",   "value": "us-south" },
      { "name": "central_logs_crn",  "value": "crn:v1:bluemix:public:logs:us-south:a/ACCOUNT_ID:INSTANCE_GUID::" },
      { "name": "child_account_ids", "value": "[\"CHILD_ID_1\",\"CHILD_ID_2\"]" }
    ]
  }]
}
EOF
```

> Note the **workspace ID** returned (format: `us-south.workspace.xxxxx`).

Remove the management account from that list unless you also want its own audit events and platform logs authorized to the central instance.

### 1.3 — Run Plan and read the inventory

```bash
ibmcloud schematics plan --id <WORKSPACE_ID>

# Wait for the job to complete, then check the log
ibmcloud schematics logs --id <WORKSPACE_ID> --act-id <ACTIVITY_ID>
```

A plan is enough to get the full listing — nothing has to be created first. Check these outputs:

| Output | What to check |
|---|---|
| `enterprise_accounts` | Every account the enterprise returned, each with `included` and `skipped_because`. This is where you confirm no account was dropped by accident. |
| `child_accounts` / `child_accounts_count` | The accounts that will be authorized. Compare the count against your enterprise inventory. |
| `excluded_accounts` | Account ID → reason it was left out. |
| `authorizations_required` | The complete matrix, keyed `<account_id>/<source_service>`. Its length is `child_accounts × source_services` (2 per account by default). |
| `central_account_id` / `central_logs_instance_guid` | Parsed from the CRN — confirm they are the logging account and the right instance. |

Two warnings are worth reacting to if they appear in the plan log:

- *"No child accounts resolved"* — every account was filtered out. Read `excluded_accounts`; the usual cause is `included_account_states` not matching the state values your enterprise returns (set it to `[]` to disable that filter), or discovery returning nothing because the identity has no enterprise access (use Layout B).
- *"No authorization target resolved"* — neither `central_logs_crn` nor `central_logs_instance_id` was set.

### 1.4 — Apply

```bash
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

Wait for `Activity status: COMPLETED`, then confirm what exists in the account:

```bash
ibmcloud iam authorization-policies
```

You should see, per child account, one policy with source `logs-router` and one with source `atracker`, each granting `Sender` on the central IBM Cloud Logs instance.

---

## Step 1b — When a child account joins or leaves the enterprise

The authorizations are the only thing that has to change centrally; the new account still needs its own `child/` workspace (Step 2).

**Layout A** — nothing to edit. Re-run plan and apply; the new account appears in `child_accounts` and two policies are added:

```bash
ibmcloud schematics plan  --id <WORKSPACE_ID>
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

**Layout B** — refresh the list, then re-apply:

```bash
# From the management account
ibmcloud target -c <MANAGEMENT_ACCOUNT_ID>
ibmcloud enterprise accounts --output JSON | jq -c '[.[] | select(.state == "ACTIVE") | .id]'

# Update the workspace variable with the new list, then plan + apply
ibmcloud schematics workspace update --id <WORKSPACE_ID> --file updated-workspace.json
ibmcloud schematics plan  --id <WORKSPACE_ID>
ibmcloud schematics apply --id <WORKSPACE_ID> --force
```

Removing an account from `child_account_ids` (or the account leaving the enterprise in Layout A) **destroys** its authorizations on the next apply, which stops its logs reaching the central instance. Deprovision its `child/` workspace first, otherwise its routes stay in place and silently fail.

### Adding another source service

If a new service has to send to the central instance, add it once and every child account gets it on the next apply:

```hcl
source_services = ["logs-router", "atracker", "some-new-service"]
```

For a different destination — centralized metrics, for example — deploy a second copy of this workspace with `source_services = ["metrics-router"]`, `target_service_name = "sysdig-monitor"` and the CRN of the central Monitoring instance.

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

| Variable | Example value | Required |
|---|---|---|
| `ibmcloud_region` | `us-south` | Defaults to `us-south` |
| `central_logs_crn` | `crn:v1:bluemix:public:logs:us-south:a/ACCT:GUID::` | **Yes** (or `central_logs_instance_id`) |
| `central_logs_instance_id` | `a1b2c3d4-...` (GUID) | Only if no CRN is given |
| `central_account_id` | `abc123...` | Only if no CRN is given |
| `child_account_ids` | `["abc123","def456"]` | Layout B only — turns discovery off |
| `enterprise_name` | `My Enterprise` | No — extra scoping filter |
| `discover_child_accounts` | `true` | No |
| `exclude_management_account` | `true` | No |
| `excluded_account_ids` | `["sandbox789"]` | No — central and management accounts are excluded automatically |
| `included_account_states` | `["ACTIVE"]` | No — set `[]` to disable the state filter |
| `source_services` | `["logs-router","atracker"]` | No |
| `target_service_name` | `logs` | No |
| `authorization_roles` | `["Sender"]` | No |

None of these are marked sensitive. A CRN, an instance GUID and an account ID are identifiers rather than credentials, and Terraform refuses to use sensitive values in `for_each` keys — which is exactly how the module iterates over child accounts.

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

# List the enterprise accounts (from the management account)
ibmcloud enterprise accounts --output JSON | jq -r '.[] | [.id, .state, .name] | @tsv'

# List the authorizations that exist (from the central logging account)
ibmcloud iam authorization-policies
```

---

## Appendix — authorizations that already exist

The IBM Terraform provider has **no data source for authorization policies**, so `central/` cannot see policies it did not create. If someone already created a `logs-router → logs` or `atracker → logs` authorization by hand, an apply will add a second, functionally identical policy. Harmless for routing, messy for auditing.

Reconcile before the first apply:

```bash
# In the central logging account — what exists today
ibmcloud iam authorization-policies --output json \
  | jq -r '.[] | [(.subjects[0].attributes[] | select(.name=="serviceName") | .value),
                  (.subjects[0].attributes[] | select(.name=="accountId")   | .value),
                  .id] | @tsv' | sort
```

Compare that against the `authorizations_required` output from the plan, then for each pre-existing policy either:

**Import it**, so Terraform adopts it instead of creating a duplicate:

```bash
terraform import \
  'ibm_iam_authorization_policy.child_to_central_logs["<ACCOUNT_ID>/logs-router"]' \
  <EXISTING_POLICY_ID>
```

Schematics does not expose `terraform import`, so run this against the same code with a local state, or delete the hand-made policy and let the workspace create it:

```bash
ibmcloud iam authorization-policy-delete <POLICY_ID> -f
```

### Creating one authorization by hand

Useful for a single urgent account, or to verify permissions before running the workspace:

```bash
ibmcloud iam authorization-policy-create logs-router logs Sender \
  --source-service-account <CHILD_ACCOUNT_ID> \
  --target-service-instance-id <CENTRAL_LOGS_INSTANCE_GUID>

ibmcloud iam authorization-policy-create atracker logs Sender \
  --source-service-account <CHILD_ACCOUNT_ID> \
  --target-service-instance-id <CENTRAL_LOGS_INSTANCE_GUID>
```

Then import both into the workspace state, or delete them before the first apply.
