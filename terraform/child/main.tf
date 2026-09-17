##############################################################################
# Child Account — IBM Cloud Logs Routing V3 + Activity Tracker routing
#
# Deploy one Schematics workspace from this module per child account.
# The central/ workspace must already be applied so the required S2S
# Sender authorizations exist before these routes are created.
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
  }
}

# No provider credentials here — Schematics injects the execution identity
# automatically. Do NOT add ibmcloud_api_key as a variable or env var.
provider "ibm" {
  region = var.ibmcloud_region
}

##############################################################################
# Section 4 — IBM Cloud Logs Routing V3
##############################################################################

# 4.1 Configure the metadata region
resource "ibm_logs_router_settings" "central" {
  primary_metadata_region = var.logs_router_metadata_region
}

# 4.2 Create the enterprise-managed Logs Routing target
resource "ibm_logs_router_target" "central" {
  destination_crn = var.central_logs_crn
  name            = "enterprise-central-logging-platform-target"
  managed_by      = "enterprise"
}

# 4.3 Route all supported platform logs to the central target
resource "ibm_logs_router_route" "central" {
  name       = "enterprise-central-logging-platform-route"
  managed_by = "enterprise"

  rules {
    action = "send"
    targets {
      id = ibm_logs_router_target.central.id
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

##############################################################################
# Section 5 — Activity Tracker Event Routing
##############################################################################

# 5.1 Create the enterprise-managed Activity Tracker target
resource "ibm_atracker_target" "central" {
  cloudlogs_endpoint {
    target_crn = var.central_logs_crn
  }

  name        = "${var.name_prefix}-audit-target"
  target_type = "cloud_logs"
  managed_by  = "enterprise"
  region      = var.atracker_target_region
}

# 5.2 Create the enterprise-managed wildcard route
#     locations = ["*"] sends audit events from ALL supported locations
resource "ibm_atracker_route" "central" {
  name       = "${var.name_prefix}-audit-route"
  managed_by = "enterprise"

  rules {
    target_ids = [ibm_atracker_target.central.id]
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
