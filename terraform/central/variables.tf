##############################################################################
# central/ — input variables
#
# Schematics renders these as workspace input fields.
# - All descriptions are plain strings (no nested blocks).
# - Do NOT add an ibmcloud_api_key variable; credentials come from the
#   Schematics execution identity.
#
# Why nothing here is marked sensitive:
#   A CRN, an instance GUID and an account ID are identifiers, not
#   credentials — they appear in the console and in every routed log record.
#   Marking them sensitive would also taint every value derived from them,
#   and Terraform refuses to use sensitive values in for_each keys, which is
#   exactly how this module iterates over child accounts.
##############################################################################

variable "ibmcloud_region" {
  description = "IBM Cloud region for the provider (e.g. us-south). Must be the region where the central COS bucket will be created."
  type        = string
  default     = "us-south"
}

##############################################################################
# Central account identity
##############################################################################

variable "central_account_id" {
  description = "Account ID of the central Logging Account (the account this workspace runs in). Leave empty to derive it automatically from cos_instance_crn, or from the default resource group when this workspace creates the COS instance."
  type        = string
  default     = ""
}

##############################################################################
# COS — the central archive bucket
#
# Two layouts:
#   A) Supply cos_instance_crn to reuse an existing COS instance.
#      Optionally supply cos_bucket_name to reuse an existing bucket.
#   B) Leave cos_instance_crn empty and this workspace provisions both a
#      new COS instance and a new bucket automatically.
##############################################################################

variable "cos_instance_crn" {
  description = "CRN of an existing IBM Cloud Object Storage instance to hold the central log archive bucket. Leave empty to have this workspace provision a new COS instance. Find it with: ibmcloud resource service-instance NAME --output json | jq -r '.[0].crn'"
  type        = string
  default     = ""
}

variable "cos_instance_name" {
  description = "Name for the COS instance created when cos_instance_crn is not supplied. Ignored when an existing COS instance is supplied."
  type        = string
  default     = "central-logs-archive"
}

variable "cos_plan" {
  description = "Plan for the COS instance created when cos_instance_crn is not supplied. Ignored when an existing COS instance is supplied."
  type        = string
  default     = "standard"
}

variable "cos_resource_group_id" {
  description = "Resource group ID for the COS instance created when cos_instance_crn is not supplied. Leave empty to use the account's Default resource group. Ignored when an existing COS instance is supplied."
  type        = string
  default     = ""
}

variable "cos_bucket_name" {
  description = "Name of the central archive COS bucket. Bucket names are globally unique across all of IBM Cloud. Leave empty to generate one automatically (a random suffix is appended to guarantee uniqueness)."
  type        = string
  default     = ""
}

variable "cos_bucket_region" {
  description = "Region for the central archive COS bucket (a regional bucket). Leave empty to use ibmcloud_region."
  type        = string
  default     = ""
}

variable "cos_bucket_storage_class" {
  description = "Storage class for the central archive COS bucket."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "vault", "cold", "smart"], var.cos_bucket_storage_class)
    error_message = "cos_bucket_storage_class must be one of: standard, vault, cold, smart."
  }
}

variable "cos_archive_days" {
  description = "Number of days after which objects in the central archive bucket transition to cos_archive_type storage. Set to 0 to disable the lifecycle transition rule. This is a bucket-level rule applied to all archived log objects."
  type        = number
  default     = 0
}

variable "cos_archive_type" {
  description = "Storage class to transition archive objects into after cos_archive_days. Used only when cos_archive_days > 0."
  type        = string
  default     = "GLACIER"

  validation {
    condition     = contains(["GLACIER", "ACCELERATED"], var.cos_archive_type)
    error_message = "cos_archive_type must be one of: GLACIER, ACCELERATED."
  }
}

##############################################################################
# Child account discovery
##############################################################################

variable "discover_child_accounts" {
  description = "Discover child accounts automatically from the IBM Cloud Enterprise. Requires the workspace identity to have enterprise access (normally an identity in the enterprise/management account). Set to false, or set child_account_ids, to skip the enterprise API call entirely."
  type        = bool
  default     = true
}

variable "child_account_ids" {
  description = "Explicit list of child account IDs. When non-empty this list wins and auto-discovery is skipped — use it when the workspace runs in a logging account that has no enterprise access. Populate it with: ibmcloud enterprise accounts --output JSON | jq -r '.[].id' (run from the enterprise account)."
  type        = list(string)
  default     = []
}

variable "enterprise_name" {
  description = "Optional display name of the IBM Cloud Enterprise (ibmcloud enterprise show). When set, discovered accounts are additionally filtered to that enterprise. Leave empty to accept every account the workspace identity can list."
  type        = string
  default     = ""
}

variable "exclude_management_account" {
  description = "Exclude the enterprise management account from discovery. It hosts the enterprise and normally routes its own logs separately."
  type        = bool
  default     = true
}

variable "excluded_account_ids" {
  description = "Additional account IDs to exclude from discovery. The central logging account and the management account are already excluded automatically, so this is only for accounts you deliberately keep out of centralized logging."
  type        = list(string)
  default     = []
}

variable "included_account_states" {
  description = "Only create authorizations for accounts whose state is in this list (case-insensitive). Keeps suspended or pending accounts out of the plan. Set to [] to disable the state filter if your enterprise reports a state value this list does not cover — check the enterprise_accounts output to see the states actually returned."
  type        = list(string)
  default     = ["ACTIVE"]
}

##############################################################################
# child/ workspace generation — feeds the child_workspace_variables and
# child_workspace_payloads outputs, which carry everything scripts/
# create-child-workspaces.sh needs to create the per-account child/
# workspaces (central_cos_bucket_crn, logs_router_metadata_region,
# atracker_target_region, name_prefix).
##############################################################################

variable "child_region_overrides" {
  description = "Per-child-account region override, keyed by account ID, used for that account's logs_router_metadata_region and atracker_target_region in the child_workspace_variables / child_workspace_payloads outputs. Accounts not listed default to ibmcloud_region."
  type        = map(string)
  default     = {}
}

variable "child_workspace_repo_url" {
  description = "Git repository URL used as template_repo.url in the generated child/ Schematics workspace-creation payloads (child_workspace_payloads output)."
  type        = string
  default     = "https://github.com/alvcapai/atracker-config-ibmcloud"
}

variable "child_workspace_repo_branch" {
  description = "Git branch used as template_repo.branch in the generated child/ Schematics workspace-creation payloads (child_workspace_payloads output)."
  type        = string
  default     = "main"
}

variable "child_workspace_name_prefix" {
  description = "Prefix prepended to the per-account name_prefix to form the generated child/ Schematics workspace name, e.g. 'child-logging-' + 'prod-us-south'."
  type        = string
  default     = "child-logging-"
}

variable "child_workspace_terraform_version" {
  description = "Schematics Terraform version type string used for the generated child/ workspace-creation payloads, e.g. terraform_v1.5. Should match the version this workspace itself was created with."
  type        = string
  default     = "terraform_v1.5"
}
