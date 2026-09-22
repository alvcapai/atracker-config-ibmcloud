##############################################################################
# Central Logging Account — COS bucket + cross-account S2S authorizations
#
# Run this workspace FIRST. It provisions (or reuses) a COS instance and
# bucket in the central account, then grants each child account's IBM Cloud
# Logs service "Writer" access to that bucket so each child's Logs instance
# can archive its data here after 30 days.
#
# Architecture
#   - Central account: COS instance + bucket only. No Cloud Logs here.
#   - Child accounts: local Cloud Logs instance (30-day hot retention) whose
#     archive is pointed at this bucket. logs-router and atracker route into
#     the local Cloud Logs instance, not into the central account.
#
# What it does
#   1. Creates (or reuses) a COS instance and bucket in this account.
#   2. Lists every account of the IBM Cloud Enterprise — or uses the explicit
#      list in var.child_account_ids when enterprise access is unavailable.
#   3. Filters that list: drops the management account, the central account
#      itself, anything in var.excluded_account_ids, and accounts whose state
#      is not in var.included_account_states.
#   4. Creates one cross-account IAM authorization policy per child account,
#      granting that account's "logs" service Writer access to the central
#      COS bucket so the child's Cloud Logs instance can archive to it.
#   5. Reports the full decision table through outputs.
#
# Where each authorization lives
#   Cross-account S2S authorizations must be created in the account that owns
#   the TARGET resource — i.e. this workspace must run in the central account
#   that holds the COS bucket.
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
  # 1.5 is required for `check` blocks and data-source lifecycle conditions.
  required_version = "~> 1.5"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.66"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

# No provider credentials here — Schematics injects the execution identity
# automatically. Do NOT add ibmcloud_api_key as a variable or env var.
provider "ibm" {
  region = var.ibmcloud_region
}

##############################################################################
# Step 1 — Resolve the central account ID and COS resources
#
# The central account ID is needed to:
#   a) exclude the central account from child discovery, and
#   b) scope the bucket-level authorization policies.
#
# It can be provided explicitly (central_account_id), derived from an existing
# COS instance CRN (cos_instance_crn), or read from the default resource group
# data source when this workspace creates the COS instance itself.
##############################################################################

locals {
  cos_crn_parts     = var.cos_instance_crn == "" ? [] : split(":", var.cos_instance_crn)
  cos_crn_is_usable = length(local.cos_crn_parts) >= 8

  create_cos_instance      = var.cos_instance_crn == ""
  generate_cos_bucket_name = var.cos_bucket_name == ""

  cos_bucket_region_resolved = var.cos_bucket_region != "" ? var.cos_bucket_region : var.ibmcloud_region
}

# Read the default resource group when creating COS ourselves — both to
# resolve the resource group ID and to obtain the account ID at plan time
# (needed for for_each key filtering, which must be known before apply).
data "ibm_resource_group" "central" {
  count      = local.create_cos_instance ? 1 : 0
  is_default = true
}

locals {
  cos_resource_group_id_resolved = (
    var.cos_resource_group_id != "" ? var.cos_resource_group_id :
    local.create_cos_instance ? data.ibm_resource_group.central[0].id : ""
  )

  # The account that owns the COS bucket — i.e. the account this workspace
  # runs in. Excluded from child discovery so the central account never
  # tries to authorize itself.
  central_account_id = (
    var.central_account_id != "" ? var.central_account_id :
    local.cos_crn_is_usable ? trimprefix(local.cos_crn_parts[6], "a/") :
    local.create_cos_instance ? data.ibm_resource_group.central[0].account_id : ""
  )
}

resource "random_string" "cos_bucket_suffix" {
  count   = local.generate_cos_bucket_name ? 1 : 0
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# Created only when no existing COS instance was supplied via cos_instance_crn.
resource "ibm_resource_instance" "cos" {
  count             = local.create_cos_instance ? 1 : 0
  name              = var.cos_instance_name
  service           = "cloud-object-storage"
  plan              = var.cos_plan
  location          = "global"
  resource_group_id = local.cos_resource_group_id_resolved
}

locals {
  cos_instance_crn_resolved = (
    var.cos_instance_crn != "" ? var.cos_instance_crn :
    local.create_cos_instance ? ibm_resource_instance.cos[0].id : ""
  )

  # COS bucket names are globally unique across all of IBM Cloud.
  cos_bucket_name_resolved = (
    var.cos_bucket_name != "" ? var.cos_bucket_name :
    local.generate_cos_bucket_name ? "${substr(replace(lower(var.cos_instance_name), "/[^a-z0-9-]+/", "-"), 0, 30)}-logs-archive-${random_string.cos_bucket_suffix[0].result}" : ""
  )
}

resource "ibm_cos_bucket" "central_archive" {
  bucket_name          = local.cos_bucket_name_resolved
  resource_instance_id = local.cos_instance_crn_resolved
  region_location      = local.cos_bucket_region_resolved
  storage_class        = var.cos_bucket_storage_class

  # Lifecycle rule: transition objects to a cheaper tier after 30 days.
  # The child Cloud Logs instance archives data here; older objects are
  # not frequently accessed and can move to vault/cold storage.
  dynamic "archive_rule" {
    for_each = var.cos_archive_days > 0 ? [1] : []
    content {
      rule_id = "logs-archive-transition"
      enable  = true
      days    = var.cos_archive_days
      type    = var.cos_archive_type
    }
  }
}

##############################################################################
# Step 2 — Discover the enterprise child accounts
##############################################################################

locals {
  discovery_enabled    = var.discover_child_accounts && length(var.child_account_ids) == 0
  filter_by_enterprise = local.discovery_enabled && var.enterprise_name != ""
}

# Optional: resolve the enterprise by name, only to scope the account list.
data "ibm_enterprises" "selected" {
  count = local.filter_by_enterprise ? 1 : 0
  name  = var.enterprise_name
}

data "ibm_enterprise_accounts" "all" {
  count = local.discovery_enabled ? 1 : 0

  lifecycle {
    postcondition {
      condition     = length(self.accounts) > 0
      error_message = "The Enterprise Management API returned no accounts. The Schematics execution identity most likely has no enterprise access — run this workspace in the enterprise (management) account, or set child_account_ids explicitly and leave discovery off."
    }
  }
}

##############################################################################
# Step 3 — Decide, per account, whether it needs the authorization
##############################################################################

locals {
  enterprise_id_filter = local.filter_by_enterprise ? data.ibm_enterprises.selected[0].enterprises[0].id : ""

  raw_accounts = local.discovery_enabled ? data.ibm_enterprise_accounts.all[0].accounts : []

  # Normalise every discovered account into a predictable shape.
  accounts = [
    for a in local.raw_accounts : {
      id            = a.id
      name          = try(coalesce(a.name, ""), "")
      state         = try(lower(a.state), "")
      enterprise_id = try(coalesce(a.enterprise_id, ""), "")
      path          = try(coalesce(a.enterprise_path, ""), "")

      # The management account is flagged by the API, and is also the account
      # whose ID equals the enterprise account ID. Check both.
      is_management = try(tostring(a.is_enterprise_account), "false") == "true" || a.id == try(a.enterprise_account_id, "")
    }
  ]

  allowed_states = [for s in var.included_account_states : lower(s)]

  # Why each discovered account was skipped. "" means "keep it".
  skip_reason = {
    for a in local.accounts : a.id => (
      contains(var.excluded_account_ids, a.id) ? "listed in excluded_account_ids" :
      (local.central_account_id != "" && a.id == local.central_account_id) ? "central logging account (owns the COS archive bucket)" :
      (a.is_management && var.exclude_management_account) ? "enterprise management account" :
      (local.enterprise_id_filter != "" && a.enterprise_id != local.enterprise_id_filter) ? "not part of enterprise \"${var.enterprise_name}\"" :
      (length(local.allowed_states) > 0 && !contains(local.allowed_states, a.state)) ? "account state \"${a.state}\" not in included_account_states" :
      ""
    )
  }

  discovered_child_accounts = {
    for a in local.accounts : a.id => a.name
    if local.skip_reason[a.id] == ""
  }

  # An explicit list always wins over discovery.
  child_accounts = length(var.child_account_ids) > 0 ? {
    for id in var.child_account_ids : id => "supplied via child_account_ids"
  } : local.discovered_child_accounts
}

# Derive workspace-generation helpers (feeds child_workspace_variables output).
locals {
  # A short, workspace-name-safe slug per child account.
  child_name_prefixes = {
    for id, name in local.child_accounts : id => substr(
      trim(
        replace(lower(name != "" ? name : id), "/[^a-z0-9]+/", "-"),
      "-"),
    0, 30)
  }

  # Region per child account (override map or this workspace's own region).
  child_regions = {
    for id in keys(local.child_accounts) : id => lookup(var.child_region_overrides, id, var.ibmcloud_region)
  }
}

# Soft warnings — visible in the plan log without blocking apply.
check "child_accounts_resolved" {
  assert {
    condition     = length(local.child_accounts) > 0
    error_message = "No child accounts resolved: this run would create zero authorizations. Check the enterprise_accounts output for the per-account skip reason, or set child_account_ids."
  }
}

check "central_account_known" {
  assert {
    condition     = local.central_account_id != ""
    error_message = "The central account ID is unknown, so the central account cannot be auto-excluded from discovery. Set central_account_id, cos_instance_crn (the account ID is derived from it), or leave create_cos_instance at its default so this workspace derives it automatically."
  }
}

check "cos_bucket_ready" {
  assert {
    condition     = local.cos_bucket_name_resolved != ""
    error_message = "COS bucket name could not be resolved. Either supply cos_bucket_name or let this workspace create the bucket."
  }
}

##############################################################################
# Step 4 — One cross-account S2S authorization per child account
#
# Grants the "logs" service in each child account "Writer" access to the
# central COS bucket so each child's IBM Cloud Logs instance can archive
# its data here after 30 days.
#
# Keys are "<account_id>" — one policy per child account (the source service
# is always "logs" for the archive use-case).
##############################################################################

resource "ibm_iam_authorization_policy" "child_logs_to_central_cos" {
  for_each = local.child_accounts

  source_service_name    = "logs"
  source_service_account = each.key

  roles       = ["Writer"]
  description = "Centralized archive: IBM Cloud Logs in child account ${each.key} may write archived log data to the central COS bucket ${local.cos_bucket_name_resolved}. Managed by Terraform."

  resource_attributes {
    name     = "serviceName"
    operator = "stringEquals"
    value    = "cloud-object-storage"
  }

  resource_attributes {
    name     = "accountId"
    operator = "stringEquals"
    value    = local.central_account_id
  }

  resource_attributes {
    name     = "serviceInstance"
    operator = "stringEquals"
    value    = regex(".*:(.*):bucket:.*", ibm_cos_bucket.central_archive.crn)[0]
  }

  resource_attributes {
    name     = "resourceType"
    operator = "stringEquals"
    value    = "bucket"
  }

  resource_attributes {
    name     = "resource"
    operator = "stringEquals"
    value    = regex("bucket:(.*)", ibm_cos_bucket.central_archive.crn)[0]
  }

  lifecycle {
    precondition {
      condition     = local.central_account_id != ""
      error_message = "central_account_id is unknown — cannot scope the COS resource attributes. Set central_account_id or cos_instance_crn."
    }

    precondition {
      condition     = local.central_account_id == "" || each.key != local.central_account_id
      error_message = "Child account ${each.key} is the central logging account itself. Remove it from child_account_ids."
    }
  }
}
