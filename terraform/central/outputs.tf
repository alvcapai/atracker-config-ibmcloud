##############################################################################
# central/ — outputs
#
# These outputs are the inventory: run `plan` and read them to see every
# account the enterprise returned, what was decided for each one, and the
# complete list of authorizations required. Nothing has to be applied to get
# the listing — a plan is enough.
##############################################################################

output "enterprise_accounts" {
  description = "Every account returned by the Enterprise Management API, with the decision taken for each one. Empty when discovery is disabled or child_account_ids is used."
  value = [
    for a in local.accounts : {
      account_id      = a.id
      account_name    = a.name
      state           = a.state
      is_management   = a.is_management
      enterprise_path = a.path
      included        = local.skip_reason[a.id] == ""
      skipped_because = local.skip_reason[a.id]
    }
  ]
}

output "enterprise_accounts_count" {
  description = "Number of accounts returned by the Enterprise Management API before filtering."
  value       = length(local.accounts)
}

output "child_accounts" {
  description = "Map of account ID to account name for every child account that will be authorized."
  value       = local.child_accounts
}

output "child_accounts_count" {
  description = "Number of child accounts that will be authorized."
  value       = length(local.child_accounts)
}

output "excluded_accounts" {
  description = "Map of account ID to the reason it was left out of the authorization set."
  value = {
    for id, reason in local.skip_reason : id => reason
    if reason != ""
  }
}

output "authorizations_required" {
  description = "The full matrix of authorizations this enterprise needs, keyed by '<account_id>/<source_service>'. Visible at plan time, before anything is created."
  value = {
    for k, v in local.authorizations : k => {
      source_service_name    = v.source_service
      source_service_account = v.account_id
      account_name           = v.account_name
      target_service_name    = var.target_service_name
      target_instance_guid   = local.central_logs_instance_guid
      roles                  = var.authorization_roles
    }
  }
}

output "authorizations_required_count" {
  description = "Number of authorizations required: child accounts x source services."
  value       = length(local.authorizations)
}

output "authorization_ids" {
  description = "Map of '<account_id>/<source_service>' to the IAM authorization policy ID created for it."
  value = {
    for k, r in ibm_iam_authorization_policy.child_to_central_logs : k => r.id
  }
}

output "logs_router_auth_ids" {
  description = "Map of child account ID to the logs-router authorization policy ID."
  value = {
    for k, r in ibm_iam_authorization_policy.child_to_central_logs :
    split("/", k)[0] => r.id
    if endswith(k, "/logs-router")
  }
}

output "atracker_auth_ids" {
  description = "Map of child account ID to the atracker authorization policy ID."
  value = {
    for k, r in ibm_iam_authorization_policy.child_to_central_logs :
    split("/", k)[0] => r.id
    if endswith(k, "/atracker")
  }
}

output "central_account_id" {
  description = "Account ID that owns the authorization target — the account this workspace must run in."
  value       = local.central_account_id
}

output "central_logs_instance_guid" {
  description = "GUID of the central instance used as the authorization target."
  value       = local.central_logs_instance_guid
}

output "central_logs_crn" {
  description = "CRN of the central IBM Cloud Logs instance used as the authorization target — either the CRN supplied via central_logs_crn, or the CRN of the instance this workspace just created. Empty when only central_logs_instance_id was supplied. Copy this value into central_logs_crn for every child/ workspace."
  value       = local.central_logs_crn_resolved
}

output "central_logs_instance_created" {
  description = "Whether this apply provisioned a new IBM Cloud Logs instance because no existing central_logs_crn or central_logs_instance_id was supplied."
  value       = local.create_central_logs_instance
}

output "child_workspace_variables" {
  description = "Per-child-account variable values for the child/ workspace (central_logs_crn, logs_router_metadata_region, atracker_target_region, name_prefix), keyed by account ID. Plain text so it is readable straight from the plan log; child_workspace_payloads below carries the same data as ready-to-submit Schematics workspace-creation JSON."
  value = {
    for id, name in local.child_accounts : id => {
      account_name                = name
      name_prefix                 = local.child_name_prefixes[id]
      ibmcloud_region             = local.child_regions[id]
      central_logs_crn            = local.central_logs_crn_resolved
      logs_router_metadata_region = local.child_regions[id]
      atracker_target_region      = local.child_regions[id]
    }
  }
}

output "child_workspace_payloads" {
  description = "One Schematics 'workspace new' JSON payload per child account — pipe each into 'ibmcloud schematics workspace new --file -', or run scripts/create-child-workspaces.sh against this workspace's ID to create them all. Each element is a JSON-encoded string (decode with jq) whose template_data.variablestore pre-fills every child/ variable. Marked sensitive because central_logs_crn is embedded as plain JSON here even though it is passed through as a secure Schematics variable."
  sensitive = true
  value = [
    for id, name in local.child_accounts : jsonencode({
      name        = "${var.child_workspace_name_prefix}${local.child_name_prefixes[id]}"
      type        = [var.child_workspace_terraform_version]
      location    = local.child_regions[id]
      description = "Deploys Logs Routing V3 and Activity Tracker enterprise-managed routes for child account ${id} (${name})."
      template_repo = {
        url    = var.child_workspace_repo_url
        branch = var.child_workspace_repo_branch
      }
      template_data = [{
        folder = "terraform/child"
        type   = var.child_workspace_terraform_version
        variablestore = [
          { name = "ibmcloud_region", value = local.child_regions[id] },
          { name = "central_logs_crn", value = local.central_logs_crn_resolved, secure = true },
          { name = "logs_router_metadata_region", value = local.child_regions[id] },
          { name = "atracker_target_region", value = local.child_regions[id] },
          { name = "name_prefix", value = local.child_name_prefixes[id] },
        ]
      }]
    })
  ]
}

output "verification_commands" {
  description = "Commands to run in the central logging account after apply, to compare what exists against authorizations_required."
  value = [
    "ibmcloud iam authorization-policies",
    "ibmcloud iam authorization-policies --output json | jq -r '.[] | [(.subjects[0].attributes[] | select(.name==\"serviceName\") | .value), (.subjects[0].attributes[] | select(.name==\"accountId\") | .value)] | @tsv' | sort",
  ]
}
