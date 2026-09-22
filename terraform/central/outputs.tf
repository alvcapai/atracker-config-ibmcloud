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
  description = "The set of cross-account archive authorizations this workspace will create, keyed by child account ID. Visible at plan time, before anything is created."
  value = {
    for id, name in local.child_accounts : id => {
      source_service_name    = "logs"
      source_service_account = id
      account_name           = name
      target_service_name    = "cloud-object-storage"
      target_bucket_name     = local.cos_bucket_name_resolved
      roles                  = ["Writer"]
    }
  }
}

output "authorizations_required_count" {
  description = "Number of cross-account archive authorizations required: one per child account."
  value       = length(local.child_accounts)
}

output "authorization_ids" {
  description = "Map of child account ID to the IAM authorization policy ID created for it."
  value = {
    for k, r in ibm_iam_authorization_policy.child_logs_to_central_cos : k => r.id
  }
}

output "central_account_id" {
  description = "Account ID of the central logging account — the account this workspace must run in."
  value       = local.central_account_id
}

output "cos_instance_crn" {
  description = "CRN of the COS instance holding the central archive bucket — either the one supplied via cos_instance_crn, or the one this workspace just created."
  value       = local.cos_instance_crn_resolved
}

output "cos_instance_created" {
  description = "Whether this apply provisioned a new COS instance because cos_instance_crn was not supplied."
  value       = local.create_cos_instance
}

output "cos_bucket_name" {
  description = "Name of the central archive COS bucket."
  value       = local.cos_bucket_name_resolved
}

output "cos_bucket_crn" {
  description = "CRN of the central archive COS bucket. Copy this value into central_cos_bucket_crn for every child/ workspace."
  value       = ibm_cos_bucket.central_archive.crn
}

output "cos_bucket_s3_endpoint_public" {
  description = "Public S3 endpoint for the central archive bucket. Used by child Cloud Logs instances configured with public service endpoints."
  value       = ibm_cos_bucket.central_archive.s3_endpoint_public
}

output "cos_bucket_s3_endpoint_private" {
  description = "Private S3 endpoint for the central archive bucket. Used by child Cloud Logs instances configured with private service endpoints."
  value       = ibm_cos_bucket.central_archive.s3_endpoint_private
}

output "child_workspace_variables" {
  description = "Per-child-account variable values for the child/ workspace (central_cos_bucket_crn, central_cos_bucket_endpoint, logs_router_metadata_region, atracker_target_region, name_prefix), keyed by account ID. Plain text so it is readable straight from the plan log; child_workspace_payloads below carries the same data as ready-to-submit Schematics workspace-creation JSON."
  value = {
    for id, name in local.child_accounts : id => {
      account_name                = name
      name_prefix                 = local.child_name_prefixes[id]
      ibmcloud_region             = local.child_regions[id]
      central_cos_bucket_crn      = ibm_cos_bucket.central_archive.crn
      central_cos_bucket_endpoint = ibm_cos_bucket.central_archive.s3_endpoint_private
      logs_router_metadata_region = local.child_regions[id]
      atracker_target_region      = local.child_regions[id]
    }
  }
}

output "child_workspace_payloads" {
  description = "One Schematics 'workspace new' JSON payload per child account — pipe each into 'ibmcloud schematics workspace new --file -', or run scripts/create-child-workspaces.sh against this workspace's ID to create them all. Marked sensitive because bucket CRNs are embedded as plain JSON here even though they are passed through as secure Schematics variables."
  sensitive   = true
  value = [
    for id, name in local.child_accounts : jsonencode({
      name        = "${var.child_workspace_name_prefix}${local.child_name_prefixes[id]}"
      type        = [var.child_workspace_terraform_version]
      location    = local.child_regions[id]
      description = "Deploys a local Cloud Logs instance + Logs Routing V3 and Activity Tracker enterprise-managed routes for child account ${id} (${name}). Archives logs to the central COS bucket after 30 days."
      template_repo = {
        url    = var.child_workspace_repo_url
        branch = var.child_workspace_repo_branch
      }
      template_data = [{
        folder = "terraform/child"
        type   = var.child_workspace_terraform_version
        variablestore = [
          { name = "ibmcloud_region", value = local.child_regions[id] },
          { name = "central_cos_bucket_crn", value = ibm_cos_bucket.central_archive.crn, secure = true },
          { name = "central_cos_bucket_endpoint", value = ibm_cos_bucket.central_archive.s3_endpoint_private },
          { name = "logs_router_metadata_region", value = local.child_regions[id] },
          { name = "atracker_target_region", value = local.child_regions[id] },
          { name = "name_prefix", value = local.child_name_prefixes[id] },
        ]
      }]
    })
  ]
}

output "verification_commands" {
  description = "Commands to run in the central logging account after apply, to verify the cross-account archive authorization policies exist."
  value = [
    "ibmcloud iam authorization-policies",
    "ibmcloud iam authorization-policies --output json | jq -r '.[] | select(.subjects[0].attributes[] | select(.name==\"serviceName\" and .value==\"logs\")) | [(.subjects[0].attributes[] | select(.name==\"accountId\") | .value), \"→ COS Writer\"] | @tsv' | sort",
  ]
}
