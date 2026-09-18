# IBM Cloud Enterprise — Centralized Logging Terraform
### Schematics-ready edition

Implements the **IBM Cloud Enterprise Centralized Logging Configuration Guide v2.0** using two IBM Cloud Schematics workspaces.

| Workspace | Directory | Account | Purpose |
|-----------|-----------|---------|---------|
| **central** | `terraform/central/` | Account that owns the central IBM Cloud Logs instance | Lists the enterprise child accounts and creates one cross-account S2S `Sender` authorization per child account per source service (`logs-router`, `atracker`) |
| **child** | `terraform/child/` | Each child account | Logs Routing V3 target + route, Activity Tracker target + wildcard route |

---

## Architecture

```
Enterprise child accounts                     Centralized Logging Account
──────────────────────────────────────────    ────────────────────────────────────
  IBM Cloud Logs Routing V3
    enterprise-managed target  ──────────────────────────────► IBM Cloud Logs
    enterprise-managed route                                    instance

  Activity Tracker Event Routing
    enterprise-managed target  ──────────────────────────────►
    wildcard route (locations=*)
```

S2S Sender authorizations (created in the central workspace) grant `logs-router` and `atracker` in each child account permission to write to the central IBM Cloud Logs instance.

---

## How `central/` finds the child accounts

One authorization is needed per child account per source service, and each one is created in the account that owns the **target** — the central IBM Cloud Logs instance. So the whole set is managed from a single workspace, driven by a list of account IDs.

That list comes from one of two places, and the module picks automatically:

```
child_account_ids set?  ──yes──►  use it verbatim, no enterprise API call
        │
        no
        ▼
discover_child_accounts ──►  Enterprise Management ListAccounts
                             └─ filter out: central account (from the CRN),
                                management account, excluded_account_ids,
                                accounts outside enterprise_name,
                                accounts whose state is not ACTIVE
                                        │
                                        ▼
                             child_accounts × source_services
                                        │
                                        ▼
                             ibm_iam_authorization_policy
                               keyed "<account_id>/<source_service>"
```

Things worth knowing about the discovery:

- **`ibm_enterprise_accounts` has no `enterprise_id` argument.** It calls `ListAccounts` unfiltered and returns every account the workspace identity can see, including accounts nested inside account groups. All scoping happens in `locals`, which is why `enterprise_name` is only an optional extra filter.
- **The call needs enterprise access.** An identity in a plain child account gets nothing back, and the data source's postcondition fails with an explanation. That is the case for `child_account_ids`.
- **Resources are keyed by account ID, not account name.** Account IDs are immutable and unique; names can be changed and can repeat inside an enterprise, which would collide in a `for_each` map.
- **A plan is the inventory.** `enterprise_accounts`, `child_accounts`, `excluded_accounts` and `authorizations_required` are all computed at plan time, so you can list everything that would be created without applying.
- **Nothing is marked sensitive.** CRNs, GUIDs and account IDs are identifiers, not credentials, and Terraform refuses to use sensitive values in `for_each` keys.
- **Pre-existing policies are invisible to Terraform.** The provider has no data source for authorization policies; see the appendix in [RUNBOOK.md](../RUNBOOK.md) for reconciling policies that were created by hand.

---

## Schematics design rules applied

| Rule | Detail |
|------|--------|
| No `backend` block | Schematics manages Terraform state internally per workspace |
| No `ibmcloud_api_key` variable | Credentials are injected by the Schematics execution identity (trusted profile or service ID) |
| `required_version = "~> 1.5"` | Pinned to a supported Schematics Terraform version. 1.5 is also the minimum for `check` blocks and data-source `postcondition` |
| Identifiers are not `sensitive` | Marking a CRN or account ID sensitive taints every derived value, and Terraform rejects sensitive values in `for_each` keys — which is how `central/` iterates over child accounts |
| Plain `description` strings | Schematics renders variable descriptions as UI field labels |
| `schematics.env` files | Provide default environment variable values for each workspace |

---

## Prerequisites

1. Provision the **IBM Cloud Logs instance** in the account that will hold the centralized logs. Record its **CRN** — `central/` derives both the instance GUID and the owning account ID from it.
2. Ensure the **Schematics execution identity** (trusted profile or service ID) has:
   - `central/` workspace: **Administrator** on IBM Cloud Logs (or on that instance) in the account the workspace runs in — required to create a cross-account authorization against it. To use auto-discovery, the same identity also needs enterprise access to list accounts (Enterprise Management service, Viewer or higher, assigned in the enterprise account). Without it, set `child_account_ids`.
   - `child/` workspace: IAM permission to manage Logs Routing and Activity Tracker resources in the child account.
3. Store this Terraform source in a **Git repository** accessible to Schematics (GitHub, GitLab, Bitbucket, or IBM Cloud hosted Git).

---

## Deployment order

### Step 1 — Create and apply the `central/` Schematics workspace

Run it in the account that owns the central IBM Cloud Logs instance.

**Via IBM Cloud Console:**

1. Go to **Schematics → Workspaces → Create workspace**.
2. Set the **Git repository URL** to this repo and the **folder** to `terraform/central`.
3. Select **Terraform version 1.5**.
4. Click **Retrieve input variables**. Schematics reads `variables.tf` and lists the fields.
5. Fill in the workspace variables:

| Variable | Value |
|---|---|
| `ibmcloud_region` | Region of the central IBM Cloud Logs instance (e.g. `us-south`) |
| `central_logs_crn` | Full CRN of an *existing* central instance — the only identifier normally needed. Leave empty (with `central_logs_instance_id`) to have this workspace provision a new instance instead |
| `enterprise_name` | *Optional.* Display name of your enterprise (`ibmcloud enterprise show`), to scope discovery to it |
| `child_account_ids` | *Only when the workspace has no enterprise access.* The explicit list of child account IDs; turns discovery off |
| `excluded_account_ids` | *Optional.* Accounts you deliberately keep out — the central and management accounts are excluded automatically |

If `central_logs_crn` and `central_logs_instance_id` are both left empty, `create_central_logs_instance` (default `true`) provisions a new IBM Cloud Logs instance in this account — named by `central_logs_instance_name`, on `central_logs_plan`, in `central_logs_resource_group_id` (default: the account's Default resource group) — and uses it as the authorization target. Set `create_central_logs_instance = false` to require an existing instance instead. The CRN used (supplied or newly created) is exposed as the `central_logs_crn` output for copying into every `child/` workspace.

6. Click **Save changes**, then **Generate plan**.
7. Review `enterprise_accounts`, `child_accounts` and `authorizations_required` in the plan — confirm every expected child account is `included` and read `skipped_because` for the ones that are not.
8. Click **Apply plan**.

**Via IBM Cloud CLI:**

```bash
ibmcloud schematics workspace new \
  --file - <<'EOF'
{
  "name": "central-logging-authorizations",
  "type": ["terraform_v1.5"],
  "template_repo": {
    "url": "https://github.com/YOUR_ORG/YOUR_REPO",
    "branch": "main"
  },
  "template_data": [{
    "folder": "terraform/central",
    "type": "terraform_v1.5",
    "variablestore": [
      { "name": "ibmcloud_region",  "value": "us-south" },
      { "name": "central_logs_crn", "value": "crn:v1:bluemix:public:logs:us-south:a/ACCOUNT_ID:INSTANCE_GUID::" },
      { "name": "enterprise_name",  "value": "My Enterprise" }
    ]
  }]
}
EOF

# Note the workspace ID, then:
ibmcloud schematics plan  --id <WORKSPACE_ID>
ibmcloud schematics apply --id <WORKSPACE_ID>
```

If the central instance lives in a dedicated logging account that cannot call the enterprise API, generate the list from the management account and pass it instead of `enterprise_name`:

```bash
ibmcloud enterprise accounts --output JSON | jq -c '[.[] | select(.state == "ACTIVE") | .id]'
# → use as: { "name": "child_account_ids", "value": "[\"CHILD_ID_1\",\"CHILD_ID_2\"]" }
```

Re-running plan and apply is all it takes when a new account joins the enterprise — see **Step 1b** in [RUNBOOK.md](../RUNBOOK.md).

---

### Step 2 — Create and apply one `child/` Schematics workspace per child account

Repeat for every child account. Each workspace is independent with its own Terraform state.

**Fastest path — generate the values, or the workspaces themselves, from `central/`'s outputs:**

- `child_workspace_variables` gives you `central_logs_crn`, `logs_router_metadata_region`, `atracker_target_region` and `name_prefix` per child account, ready to paste into the Console's **Retrieve input variables** form.
- `child_workspace_payloads` gives you one ready-to-submit `ibmcloud schematics workspace new --file -` JSON payload per child account (sensitive — read it with `ibmcloud schematics output --id <CENTRAL_WORKSPACE_ID> --output json`). `scripts/create-child-workspaces.sh <CENTRAL_WORKSPACE_ID>` consumes this output directly and creates every missing child workspace for you.

**Via IBM Cloud Console:**

1. Go to **Schematics → Workspaces → Create workspace** (switch to the child account context).
2. Set the **Git repository URL** to this repo and the **folder** to `terraform/child`.
3. Select **Terraform version 1.5**.
4. Click **Retrieve input variables** and fill in:

| Variable | Value |
|---|---|
| `ibmcloud_region` | Child account primary region (e.g. `us-south`) |
| `central_logs_crn` | Full CRN of the central IBM Cloud Logs instance (**sensitive**) |
| `logs_router_metadata_region` | Metadata region for Logs Routing V3 (e.g. `us-south`) |
| `atracker_target_region` | Region for Activity Tracker target (e.g. `us-south`) |
| `name_prefix` | Short unique name identifying this child account (e.g. `prod-us-south`) |

5. **Generate plan first.** Review any change to `ibm_logs_router_settings` carefully in existing accounts.
6. **Apply plan.**

**Via IBM Cloud CLI:**

```bash
ibmcloud schematics workspace new \
  --file - <<'EOF'
{
  "name": "child-logging-prod-us-south",
  "type": ["terraform_v1.5"],
  "template_repo": {
    "url": "https://github.com/YOUR_ORG/YOUR_REPO",
    "branch": "main"
  },
  "template_data": [{
    "folder": "terraform/child",
    "type": "terraform_v1.5",
    "variablestore": [
      { "name": "ibmcloud_region",             "value": "us-south" },
      { "name": "central_logs_crn",            "value": "crn:v1:bluemix:...", "secure": true },
      { "name": "logs_router_metadata_region", "value": "us-south" },
      { "name": "atracker_target_region",      "value": "us-south" },
      { "name": "name_prefix",                 "value": "prod-us-south" }
    ]
  }]
}
EOF

ibmcloud schematics plan  --id <WORKSPACE_ID>
ibmcloud schematics apply --id <WORKSPACE_ID>
```

---

## Validation

After applying each child workspace run the control-plane checks (in the child account):

```bash
# Activity Tracker
ibmcloud atracker target ls
ibmcloud atracker route ls

# Logs Routing V3
ibmcloud logs-router target list
ibmcloud logs-router route list
```

Confirm targets point to the central CRN and that the Activity Tracker route includes `locations = ["*"]`.
Then open the **IBM Cloud Logs dashboard** in the central account and verify audit events and platform logs are arriving.

---

## Post-validation — IAM guardrails

After stable data-plane validation, assign the IAM Action Control guardrail template to protect the enterprise-managed routing resources.

Protect at minimum:

**Logs Routing:** `logs-router.route.update`, `logs-router.route.delete`, `logs-router.target.update`, `logs-router.target.delete`

**Activity Tracker:** `atracker.route.update`, `atracker.route.delete`, `atracker.target.update`, `atracker.target.delete`, `atracker.setting.update`

See [Enterprise IAM Action Control templates](https://cloud.ibm.com/docs/enterprise-management?topic=enterprise-management-act-template-create).

---

## `central/` outputs

| Output | Use |
|---|---|
| `enterprise_accounts` | Every account returned by the enterprise, with `state`, `is_management`, `enterprise_path`, `included` and `skipped_because` |
| `enterprise_accounts_count` | How many accounts the API returned before filtering |
| `child_accounts` / `child_accounts_count` | Account ID → name for the accounts that get authorized |
| `excluded_accounts` | Account ID → reason it was skipped |
| `authorizations_required` / `authorizations_required_count` | The full matrix, keyed `<account_id>/<source_service>`, with source, target and roles — available at plan time |
| `authorization_ids` | `<account_id>/<source_service>` → IAM policy ID actually created |
| `child_workspace_variables` | Per-child-account `central_logs_crn`, `logs_router_metadata_region`, `atracker_target_region`, `name_prefix` — plain text, readable straight from the plan log |
| `child_workspace_payloads` | Per-child-account `ibmcloud schematics workspace new` JSON payload with those variables pre-filled (sensitive) — feed to `scripts/create-child-workspaces.sh` |
| `logs_router_auth_ids` / `atracker_auth_ids` | Per-service views of the same, keyed by account ID |
| `central_account_id` / `central_logs_instance_guid` | Parsed from `central_logs_crn`, to confirm the target |
| `verification_commands` | Ready-to-paste commands to list what exists in the central account |

---

## Migrating from the earlier version of `central/`

The previous `central/main.tf` passed `enterprise_id` to `data "ibm_enterprise_accounts"`. That argument does not exist in the provider schema, so the workspace failed at `plan` with *"An argument named `enterprise_id` is not expected here"* — which means it can never have applied, and there is no state to migrate. Create or update the workspace with the variables above and plan again.

If you did somehow apply an earlier variant, note that resource keys changed from account **name** to `"<account_id>/<source_service>"`, so Terraform would replace the policies. Schematics does not expose `terraform state mv`; the practical path is to destroy that workspace and re-apply this one, accepting a short gap in routing.

---

## References

- [IBM Cloud Logs Routing V3 overview](https://cloud.ibm.com/docs/logs-router?topic=logs-router-about-v3)
- [Enterprise-managed platform logs routing](https://cloud.ibm.com/docs/logs-router?topic=logs-router-enterprise-routing-scenario)
- [Activity Tracker enterprise routing scenario](https://cloud.ibm.com/docs/atracker?topic=atracker-enterprise-routing-scenario)
- [IBM Cloud Logs alerting / Event Notifications](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-event-notifications-about)
- [IBM Terraform provider](https://registry.terraform.io/providers/IBM-Cloud/ibm/latest)
- [IBM Cloud Schematics workspaces](https://cloud.ibm.com/docs/schematics?topic=schematics-workspaces)
- [Schematics Terraform version lifecycle](https://cloud.ibm.com/docs/schematics?topic=schematics-deprecate-tf-version)
