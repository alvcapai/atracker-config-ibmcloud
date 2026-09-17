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

output "verification_commands" {
  description = "Commands to run in the central logging account after apply, to compare what exists against authorizations_required."
  value = [
    "ibmcloud iam authorization-policies",
    "ibmcloud iam authorization-policies --output json | jq -r '.[] | [(.subjects[0].attributes[] | select(.name==\"serviceName\") | .value), (.subjects[0].attributes[] | select(.name==\"accountId\") | .value)] | @tsv' | sort",
  ]
}
