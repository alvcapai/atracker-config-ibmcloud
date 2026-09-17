# IBM Cloud Enterprise — Centralized Logging Terraform
### Schematics-ready edition

Implements the **IBM Cloud Enterprise Centralized Logging Configuration Guide v2.0** using two IBM Cloud Schematics workspaces.

| Workspace | Directory | Account | Purpose |
|-----------|-----------|---------|---------|
| **central** | `terraform/central/` | Logging Account | Auto-discovers all enterprise child accounts and creates cross-account S2S Sender authorizations for `logs-router` and `atracker` |
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

S2S Sender authorizations (created in the central workspace) grant `logs-router` and `atracker` in each child account permission to write to the central IBM Cloud Logs instance. Child accounts are **auto-discovered** from the IBM Cloud Enterprise — no manual account list is needed.

---

## Schematics design rules applied

| Rule | Detail |
|------|--------|
| No `backend` block | Schematics manages Terraform state internally per workspace |
| No `ibmcloud_api_key` variable | Credentials are injected by the Schematics execution identity (trusted profile or service ID) |
| `required_version = "~> 1.5"` | Pinned to a supported Schematics Terraform version |
| `sensitive = true` on secrets | `central_logs_instance_id` and `central_logs_crn` are masked in Schematics logs and UI |
| Plain `description` strings | Schematics renders variable descriptions as UI field labels |
| `schematics.env` files | Provide default environment variable values for each workspace |

---

## Prerequisites

1. Provision the **IBM Cloud Logs instance** in the centralized Logging Account. Record its CRN and instance GUID.
2. Ensure the **Schematics execution identity** (trusted profile or service ID) has:
   - `central/` workspace: IAM permission to manage authorization policies in the Logging Account and Enterprise Administrator or Viewer access to list accounts.
   - `child/` workspace: IAM permission to manage Logs Routing and Activity Tracker resources in the child account.
3. Store this Terraform source in a **Git repository** accessible to Schematics (GitHub, GitLab, Bitbucket, or IBM Cloud hosted Git).

---

## Deployment order

### Step 1 — Create and apply the `central/` Schematics workspace (Logging Account)

**Via IBM Cloud Console:**

1. Go to **Schematics → Workspaces → Create workspace**.
2. Set the **Git repository URL** to this repo and the **folder** to `terraform/central`.
3. Select **Terraform version 1.5**.
4. Click **Retrieve input variables**. Schematics reads `variables.tf` and lists the fields.
5. Fill in the workspace variables:

| Variable | Value |
|---|---|
| `ibmcloud_region` | Region of the central IBM Cloud Logs instance (e.g. `us-south`) |
| `enterprise_name` | Display name of your IBM Cloud Enterprise (`ibmcloud enterprise show`) |
| `central_logs_instance_id` | GUID of the central IBM Cloud Logs instance (**sensitive**) |
| `excluded_account_ids` | List containing the management account ID and the central Logging Account ID |

6. Click **Save changes**, then **Generate plan**.
7. Review the `discovered_child_accounts` output in the plan — confirm all expected child accounts appear.
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
      { "name": "ibmcloud_region",          "value": "us-south" },
      { "name": "enterprise_name",          "value": "My Enterprise" },
      { "name": "central_logs_instance_id", "value": "REPLACE_GUID", "secure": true },
      { "name": "excluded_account_ids",     "value": "[\"MGMT_ACCT_ID\",\"LOGGING_ACCT_ID\"]" }
    ]
  }]
}
EOF

# Note the workspace ID, then:
ibmcloud schematics plan  --id <WORKSPACE_ID>
ibmcloud schematics apply --id <WORKSPACE_ID>
```

---

### Step 2 — Create and apply one `child/` Schematics workspace per child account

Repeat for every child account. Each workspace is independent with its own Terraform state.

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

## References

- [IBM Cloud Logs Routing V3 overview](https://cloud.ibm.com/docs/logs-router?topic=logs-router-about-v3)
- [Enterprise-managed platform logs routing](https://cloud.ibm.com/docs/logs-router?topic=logs-router-enterprise-routing-scenario)
- [Activity Tracker enterprise routing scenario](https://cloud.ibm.com/docs/atracker?topic=atracker-enterprise-routing-scenario)
- [IBM Cloud Logs alerting / Event Notifications](https://cloud.ibm.com/docs/cloud-logs?topic=cloud-logs-event-notifications-about)
- [IBM Terraform provider](https://registry.terraform.io/providers/IBM-Cloud/ibm/latest)
- [IBM Cloud Schematics workspaces](https://cloud.ibm.com/docs/schematics?topic=schematics-workspaces)
- [Schematics Terraform version lifecycle](https://cloud.ibm.com/docs/schematics?topic=schematics-deprecate-tf-version)
