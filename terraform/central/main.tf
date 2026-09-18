##############################################################################
# Central Logging Account — cross-account S2S authorizations
#
# Run this workspace FIRST so every child account has the required
# logs-router → IBM Cloud Logs and atracker → IBM Cloud Logs "Sender"
# authorization before the child routes are applied.
#
# What it does
#   1. Resolves the authorization target: an existing IBM Cloud Logs instance
#      given via central_logs_crn / central_logs_instance_id, or — when
#      neither is supplied and create_central_logs_instance is true (the
#      default) — a brand new instance this workspace provisions itself.
#   2. Lists every account of the IBM Cloud Enterprise (Enterprise Management
#      ListAccounts API) — or uses the explicit list in var.child_account_ids
#      when the workspace identity has no enterprise access.
#   3. Filters that list: drops the enterprise management account, the central
#      logging account itself, anything in var.excluded_account_ids and any
#      account whose state is not in var.included_account_states.
#   4. Creates one IAM authorization policy per (child account × source
#      service) pair, all targeting the central IBM Cloud Logs instance.
#   5. Reports the full decision table through outputs, so the plan itself is
#      the inventory of "authorizations needed vs. authorizations created".
#
# Where each authorization lives
#   Cross-account service-to-service authorizations are created in the account
#   that owns the TARGET resource — i.e. this workspace must run in the account
#   that holds the central IBM Cloud Logs instance. See:
#   https://cloud.ibm.com/docs/logs-router?topic=logs-router-enterprise-routing-scenario
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
  }
}

# No provider credentials here — Schematics injects the execution identity
# automatically. Do NOT add ibmcloud_api_key as a variable or env var.
provider "ibm" {
  region = var.ibmcloud_region
}

##############################################################################
# Step 1 — Resolve the authorization target (instance GUID + owning account)
#
# central_logs_crn is the preferred input. Its shape is:
#   crn:v1:bluemix:public:logs:<region>:a/<account_id>:<instance_guid>::
#    0  1    2       3      4     5        6                7        8 9
#
# When neither central_logs_crn nor central_logs_instance_id is supplied and
# var.create_central_logs_instance is true (the default), this workspace
# provisions a new IBM Cloud Logs instance itself and uses it as the
# authorization target, so deployment can proceed without a pre-existing one.
##############################################################################

locals {
  input_crn_parts  = var.central_logs_crn == "" ? [] : split(":", var.central_logs_crn)
  input_crn_usable = length(local.input_crn_parts) >= 8

  # An existing instance was supplied, either as a CRN or a bare GUID.
  existing_instance_supplied = local.input_crn_usable || var.central_logs_instance_id != ""

  create_central_logs_instance = var.create_central_logs_instance && !local.existing_instance_supplied
}

# Always read the account's default resource group when creating a new
# instance — both to resolve resource_group_id when the caller did not
# supply one, and to read the account ID up front. A data source is read at
# plan time (unlike a resource's computed attributes, which are only known
# after apply), which keeps central_account_id — and therefore the for_each
# keys on local.authorizations, which are filtered by it — known during
# plan instead of depending on the instance this same apply is about to
# create.
data "ibm_resource_group" "central_logs" {
  count      = local.create_central_logs_instance ? 1 : 0
  is_default = true
}

# Created only when no existing central Logs instance was supplied. Runs in
# this workspace's own account, which is exactly the account the central
# instance must live in.
resource "ibm_resource_instance" "central_logs" {
  count             = local.create_central_logs_instance ? 1 : 0
  name              = var.central_logs_instance_name
  service           = "logs"
  plan              = var.central_logs_plan
  location          = var.ibmcloud_region
  resource_group_id = var.central_logs_resource_group_id != "" ? var.central_logs_resource_group_id : data.ibm_resource_group.central_logs[0].id

  parameters = {
    service-endpoints = var.central_logs_service_endpoints
  }
}

locals {
  # GUID of the central IBM Cloud Logs instance (the authorization target).
  # Only used as a resource attribute (never a for_each key), so it is fine
  # for this to stay unknown until the new instance is actually created.
  central_logs_instance_guid = (
    var.central_logs_instance_id != "" ? var.central_logs_instance_id :
    local.input_crn_usable ? local.input_crn_parts[7] :
    local.create_central_logs_instance ? ibm_resource_instance.central_logs[0].guid : ""
  )

  # Account that owns the target instance — i.e. the account this workspace
  # runs in. It is excluded from discovery so the account never authorizes
  # itself, and that exclusion drives a for_each key, so this must be known
  # at plan time: from the supplied CRN/variable, or from the resource-group
  # data source above — never from the not-yet-created instance's CRN.
  central_account_id = (
    var.central_account_id != "" ? var.central_account_id :
    local.input_crn_usable ? trimprefix(local.input_crn_parts[6], "a/") :
    local.create_central_logs_instance ? data.ibm_resource_group.central_logs[0].account_id : ""
  )

  # Full CRN to surface as an output, for copying into child/ workspaces.
  central_logs_crn_resolved = (
    local.input_crn_usable ? var.central_logs_crn :
    local.create_central_logs_instance ? ibm_resource_instance.central_logs[0].crn : ""
  )
}

##############################################################################
# Step 2 — Discover the enterprise child accounts
#
# ibm_enterprise_accounts takes NO enterprise_id argument. It calls the
# Enterprise Management ListAccounts API unfiltered and returns every account
# the workspace identity can see, including accounts nested inside account
# groups. All scoping is therefore done locally, in step 3.
#
# The call only succeeds for an identity with enterprise access (normally an
# identity in the enterprise/management account). If the workspace runs in a
# plain child account, set var.child_account_ids instead and discovery is
# skipped entirely — no enterprise API call is made.
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
# Step 3 — Decide, per account, whether it needs the authorizations
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
      (local.central_account_id != "" && a.id == local.central_account_id) ? "central logging account (owns the authorization target)" :
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

  # The complete matrix of authorizations this enterprise needs:
  # one entry per child account per source service.
  authorizations = {
    for pair in setproduct(keys(local.child_accounts), var.source_services) :
    "${pair[0]}/${pair[1]}" => {
      account_id     = pair[0]
      account_name   = local.child_accounts[pair[0]]
      source_service = pair[1]
    }
  }
}

##############################################################################
# Step 3b — Derive what each child/ workspace needs to be created with
#
# Feeds child_workspace_variables and child_workspace_payloads (outputs.tf),
# which carry everything scripts/create-child-workspaces.sh needs to create
# one child/ Schematics workspace per discovered child account.
##############################################################################

locals {
  # A short, workspace-name-safe slug per child account: lower-cased account
  # name (falling back to the account ID when the name is empty), anything
  # outside [a-z0-9-] collapsed to "-", leading/trailing "-" trimmed, capped
  # at 30 chars.
  child_name_prefixes = {
    for id, name in local.child_accounts : id => substr(
      trim(
        replace(lower(name != "" ? name : id), "/[^a-z0-9]+/", "-"),
      "-"),
    0, 30)
  }

  # Region used for logs_router_metadata_region / atracker_target_region in
  # each child/ workspace: the per-account override if one was given,
  # otherwise this workspace's own region.
  child_regions = {
    for id in keys(local.child_accounts) : id => lookup(var.child_region_overrides, id, var.ibmcloud_region)
  }
}

# Warnings surfaced in the Schematics plan log rather than hard failures, so a
# misconfigured filter is visible instead of silently producing nothing.
check "child_accounts_resolved" {
  assert {
    condition     = length(local.child_accounts) > 0
    error_message = "No child accounts resolved: this run would create zero authorizations. Check the enterprise_accounts output for the per-account skip reason, or set child_account_ids."
  }
}

check "target_resolved" {
  assert {
    condition     = local.central_logs_instance_guid != ""
    error_message = "No authorization target resolved and create_central_logs_instance is false. Set central_logs_crn (preferred — the account ID is derived from it), central_logs_instance_id, or leave create_central_logs_instance at its default (true) so this workspace provisions a new IBM Cloud Logs instance."
  }
}

check "central_account_known" {
  assert {
    condition     = local.central_account_id != ""
    error_message = "The central account ID is unknown, so the central logging account cannot be auto-excluded from discovery. Set central_logs_crn (preferred), central_account_id, or leave create_central_logs_instance at its default (true) so this workspace provisions a new instance and derives the account ID from it."
  }
}

##############################################################################
# Step 4 — One S2S authorization per child account per source service
#
# Keys are "<account_id>/<source_service>". Account IDs are immutable, so
# renaming an account in the enterprise does not recreate its policies.
##############################################################################

resource "ibm_iam_authorization_policy" "child_to_central_logs" {
  for_each = local.authorizations

  source_service_name    = each.value.source_service
  source_service_account = each.value.account_id

  target_service_name         = var.target_service_name
  target_resource_instance_id = local.central_logs_instance_guid

  roles = var.authorization_roles

  description = "Centralized logging: ${each.value.source_service} in child account ${each.value.account_id} may send to the central ${var.target_service_name} instance. Managed by Terraform."

  lifecycle {
    precondition {
      condition     = local.central_logs_instance_guid != ""
      error_message = "No authorization target resolved. Set central_logs_crn (preferred), central_logs_instance_id, or leave create_central_logs_instance at its default (true)."
    }

    precondition {
      condition     = local.central_account_id == "" || each.value.account_id != local.central_account_id
      error_message = "Child account ${each.value.account_id} is the central logging account itself. Remove it from child_account_ids — an account does not need an authorization to its own instance."
    }
  }
}
