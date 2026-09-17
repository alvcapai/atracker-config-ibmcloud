##############################################################################
# central/ — outputs
##############################################################################

output "discovered_child_accounts" {
  description = "Map of account name → account ID discovered from the enterprise (after exclusions). Useful for confirming the correct set before apply."
  value       = local.child_accounts
}

output "logs_router_auth_ids" {
  description = "Map of child account name → logs-router S2S authorization ID."
  value = {
    for k, v in ibm_iam_authorization_policy.logs_router_to_central_logs :
    k => v.id
  }
}

output "atracker_auth_ids" {
  description = "Map of child account name → atracker S2S authorization ID."
  value = {
    for k, v in ibm_iam_authorization_policy.atracker_to_central_logs :
    k => v.id
  }
}
