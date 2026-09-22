##############################################################################
# Child Account — Local Cloud Logs instance + Logs Routing V3 + Activity Tracker
#
# Deploy one Schematics workspace from this module per child account.
# The central/ workspace must already be applied so the required cross-account
# IAM authorization (child "logs" service → central COS bucket Writer) exists
# before this workspace tries to configure the Logs instance archive.
#
# Architecture
#   - This workspace creates a local IBM Cloud Logs instance in the child
#     account. Logs are kept searchable ("hot") for var.logs_retention_days
#     (default 30 days).
#   - After the hot-retention window, the Logs instance archives data to the
#     central COS bucket provisioned by the central/ workspace.
#   - logs-router and atracker both route into this local Logs instance.
#     Nothing routes directly to the central account any more.
#
# Schematics notes:
#   - No backend block: Schematics manages state internally per workspace.
#   - No ibmcloud_api_key variable: credentials are injected by the
#     Schematics execution identity (trusted profile or service ID).
#   - Terraform version is pinned to the latest version supported by
#     Schematics (1.5.x). Check the Schematics version lifecycle page
#     before upgrading: https://cloud.ibm.com/docs/schematics?topic=schematics-deprecate-tf-version
#   - Run terraform plan first and review ibm_logs_router_settings changes
#     carefully in existing accounts before applying.
##############################################################################

terraform {
  # Pin to a Schematics-supported Terraform version.
  required_version = "~> 1.5"

  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.66"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

# No provider credentials here — Schematics injects the execution identity
# automatically. Do NOT add ibmcloud_api_key as a variable or env var.
provider "ibm" {
  region = var.ibmcloud_region
}

##############################################################################
# Section 1 — Local IBM Cloud Logs instance
#
# This instance is the destination for both Logs Routing V3 and Activity
# Tracker in this child account. It archives ingested data to the central COS
# bucket after var.logs_retention_days days.
#
# Pre-requisite: the central/ workspace must have already applied the
# cross-account IAM authorization (child "logs" service → central COS bucket
# Writer). The Logs instance create call is rejected outright if that
# authorization is not yet effective — hence the time_sleep below.
##############################################################################

# Resolve the resource group for the Logs instance.
data "ibm_resource_group" "logs" {
  count      = var.logs_resource_group_id == "" ? 1 : 0
  is_default = true
}

locals {
  logs_resource_group_id_resolved = (
    var.logs_resource_group_id != "" ? var.logs_resource_group_id :
    data.ibm_resource_group.logs[0].id
  )
}

# IAM authorization policies can take up to ~30 s to propagate globally.
# The Logs instance create call fails immediately if the archive authorization
# is not yet effective, so we pause briefly after the central/ workspace
# applies the policy. In practice, applying the child workspace seconds after
# the central workspace finishes is safe; this guard is here for automated
# pipelines that chain the two applies without any gap.
resource "time_sleep" "wait_for_archive_authorization" {
  create_duration = "30s"
}

resource "ibm_resource_instance" "logs" {
  depends_on        = [time_sleep.wait_for_archive_authorization]
  name              = "${var.name_prefix}-logs"
  service           = "logs"
  plan              = var.logs_plan
  location          = var.ibmcloud_region
  resource_group_id = local.logs_resource_group_id_resolved

  parameters = {
    service-endpoints    = var.logs_service_endpoints
    retention_period     = var.logs_retention_days
    logs_bucket_crn      = var.central_cos_bucket_crn
    logs_bucket_endpoint = var.central_cos_bucket_endpoint
  }
}

##############################################################################
# Section 2 — IBM Cloud Logs Routing V3
##############################################################################

# 2.1 Configure the metadata region
resource "ibm_logs_router_settings" "local" {
  primary_metadata_region = var.logs_router_metadata_region
}

# 2.2 Create the enterprise-managed Logs Routing target pointing to the local
#     Logs instance.
#     Explicit depends_on: the target API rejects the request with
#     "primary_metadata_region in settings is empty" unless the account's
#     Logs Routing settings are already in place.
resource "ibm_logs_router_target" "local" {
  destination_crn = ibm_resource_instance.logs.crn
  name            = "${var.name_prefix}-platform-logs-target"
  managed_by      = "enterprise"

  depends_on = [ibm_logs_router_settings.local]
}

# 2.3 Route all supported platform logs to the local target
resource "ibm_logs_router_route" "local" {
  name       = "${var.name_prefix}-platform-logs-route"
  managed_by = "enterprise"

  rules {
    action = "send"
    targets {
      id = ibm_logs_router_target.local.id
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

##############################################################################
# Section 3 — Activity Tracker Event Routing
##############################################################################

# 3.1 Create the enterprise-managed Activity Tracker target pointing to the
#     local Logs instance.
resource "ibm_atracker_target" "local" {
  cloudlogs_endpoint {
    target_crn = ibm_resource_instance.logs.crn
  }

  name        = "${var.name_prefix}-audit-target"
  target_type = "cloud_logs"
  managed_by  = "enterprise"
  region      = var.atracker_target_region
}

# 3.2 Create the enterprise-managed wildcard route
#     locations = ["*"] sends audit events from ALL supported locations
resource "ibm_atracker_route" "local" {
  name       = "${var.name_prefix}-audit-route"
  managed_by = "enterprise"

  rules {
    target_ids = [ibm_atracker_target.local.id]
    locations  = ["*"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Note: ibm_atracker_settings is intentionally NOT managed here.
# Per the guide (section 5.3), changing atracker settings can replace
# omitted values and break pre-existing account configurations.
# Manage settings explicitly in a separate governance workspace if required.
