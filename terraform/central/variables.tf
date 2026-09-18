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
  description = "IBM Cloud region for the provider (e.g. us-south). Must be the region where the central IBM Cloud Logs instance is located."
  type        = string
  default     = "us-south"
}

##############################################################################
# Authorization target — the central IBM Cloud Logs instance
##############################################################################

variable "central_logs_crn" {
  description = "Full CRN of the IBM Cloud Logs instance in the centralized Logging Account, e.g. crn:v1:bluemix:public:logs:us-south:a/ACCOUNTID:INSTANCEGUID::. Preferred input: both the instance GUID and the owning account ID are derived from it. Find it with: ibmcloud resource service-instance NAME --output json | jq -r '.[0].crn'"
  type        = string
  default     = ""

  validation {
    condition     = var.central_logs_crn == "" || length(split(":", var.central_logs_crn)) >= 8
    error_message = "central_logs_crn must be a full IBM Cloud CRN with at least 8 colon-separated segments, or an empty string."
  }
}

variable "central_logs_instance_id" {
  description = "GUID of the central IBM Cloud Logs instance. Only needed when central_logs_crn is not supplied. Find it with: ibmcloud resource service-instance NAME --output json | jq -r '.[0].guid'"
  type        = string
  default     = ""
}

variable "central_account_id" {
  description = "Account ID of the centralized Logging Account (the account this workspace runs in). Leave empty to derive it from central_logs_crn. Used to exclude the central account from discovery so it never authorizes itself."
  type        = string
  default     = ""
}

##############################################################################
# Auto-provisioning — used only when no existing instance was supplied
##############################################################################

variable "create_central_logs_instance" {
  description = "When true (default) and neither central_logs_crn nor central_logs_instance_id is set, provision a new IBM Cloud Logs instance in this account and use it as the authorization target. Set to false to require an existing instance instead of creating one."
  type        = bool
  default     = true
}

variable "central_logs_instance_name" {
  description = "Name for the IBM Cloud Logs instance created when create_central_logs_instance applies. Ignored when an existing instance is supplied."
  type        = string
  default     = "central-logging"
}

variable "central_logs_plan" {
  description = "Plan for the IBM Cloud Logs instance created when create_central_logs_instance applies. Ignored when an existing instance is supplied."
  type        = string
  default     = "standard"
}

variable "central_logs_resource_group_id" {
  description = "Resource group ID for the IBM Cloud Logs instance created when create_central_logs_instance applies. Leave empty to use the account's Default resource group. Ignored when an existing instance is supplied."
  type        = string
  default     = ""
}

variable "central_logs_service_endpoints" {
  description = "Service endpoints for the IBM Cloud Logs instance created when create_central_logs_instance applies: public, private, or public-and-private. Ignored when an existing instance is supplied."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private", "public-and-private"], var.central_logs_service_endpoints)
    error_message = "central_logs_service_endpoints must be one of: public, private, public-and-private."
  }
}

variable "target_service_name" {
  description = "Target service of the authorizations. Keep the default 'logs' for IBM Cloud Logs. Change it only if you reuse this module for another centralized destination, e.g. 'sysdig-monitor' for IBM Cloud Monitoring with metrics-router as the source service."
  type        = string
  default     = "logs"
}

variable "authorization_roles" {
  description = "IAM roles granted by each authorization. The enterprise routing scenarios for both Logs Routing and Activity Tracker require exactly ['Sender']."
  type        = list(string)
  default     = ["Sender"]

  validation {
    condition     = length(var.authorization_roles) > 0
    error_message = "authorization_roles must contain at least one role."
  }
}

variable "source_services" {
  description = "Source services in each child account that need to send to the central instance. Defaults to the two services required by the centralized logging guide: logs-router (platform logs) and atracker (audit events). Add a service here and every child account gets the extra authorization on the next apply."
  type        = list(string)
  default     = ["logs-router", "atracker"]

  validation {
    condition     = length(var.source_services) > 0
    error_message = "source_services must contain at least one service name."
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
# workspaces (central_logs_crn, logs_router_metadata_region,
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
