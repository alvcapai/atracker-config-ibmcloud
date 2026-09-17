##############################################################################
# Central Logging Account — cross-account S2S authorizations
#
# Run this workspace FIRST so every child account has the required
# logs-router → IBM Cloud Logs and atracker → IBM Cloud Logs Sender
# authorization before child routes are applied.
#
# Child accounts are discovered automatically from the IBM Cloud Enterprise
# via data sources — no manual account ID list is required.
#
# Schematics notes:
#   - No backend block: Schematics manages state internally per workspace.
#   - No ibmcloud_api_key variable: credentials are injected by the
#     Schematics execution identity (trusted profile or service ID).
#   - Terraform version is pinned to the latest version supported by
#     Schematics (1.5.x). Check the Schematics version lifecycle page
#     before upgrading: https://cloud.ibm.com/docs/schematics?topic=schematics-deprecate-tf-version
##############################################################################

terraform {
  # Pin to a Schematics-supported Terraform version.
  required_version = "~> 1.5"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.66"
    }
  }
}

# No provider credentials here — Schematics injects the execution identity
# automatically. Do NOT add ibmcloud_api_key as a variable or env var.
provider "ibm" {
  region = var.ibmcloud_region
}

##############################################################################
# Discover all enterprise child accounts dynamically
##############################################################################

# Look up the enterprise by name
data "ibm_enterprises" "all" {
  name = var.enterprise_name
}

# List every account in that enterprise
data "ibm_enterprise_accounts" "all" {
  enterprise_id = data.ibm_enterprises.all.enterprises[0].id
}

# Build a map of { account_name => account_id } for every account that is NOT
# the central/management account (excluded via var.excluded_account_ids).
locals {
  child_accounts = {
    for acct in data.ibm_enterprise_accounts.all.accounts :
    acct.name => acct.id
    if !contains(var.excluded_account_ids, acct.id)
  }
}

##############################################################################
# S2S authorizations — one pair per discovered child account
##############################################################################

# logs-router → central IBM Cloud Logs
resource "ibm_iam_authorization_policy" "logs_router_to_central_logs" {
  for_each = local.child_accounts

  source_service_name         = "logs-router"
  source_service_account      = each.value
  target_service_name         = "logs"
  target_resource_instance_id = var.central_logs_instance_id
  roles                       = ["Sender"]
}

# atracker → central IBM Cloud Logs
resource "ibm_iam_authorization_policy" "atracker_to_central_logs" {
  for_each = local.child_accounts

  source_service_name         = "atracker"
  source_service_account      = each.value
  target_service_name         = "logs"
  target_resource_instance_id = var.central_logs_instance_id
  roles                       = ["Sender"]
}
