#!/usr/bin/env bash
# =============================================================================
# create-child-workspaces.sh
#
# Reads the child_workspace_payloads output from the central Schematics
# workspace and automatically creates one child workspace per discovered
# enterprise child account.
#
# Prerequisites:
#   - ibmcloud CLI with the schematics and enterprise plugins installed
#   - jq >= 1.6
#   - Logged in to the IBM Cloud CLI as the CENTRAL LOGGING ACCOUNT
#     (ibmcloud login --sso && ibmcloud target -c <CENTRAL_LOGGING_ACCOUNT_ID>)
#   - The central workspace must have been applied successfully first
#
# Usage:
#   ./scripts/create-child-workspaces.sh <CENTRAL_WORKSPACE_ID>
#
# Example:
#   ./scripts/create-child-workspaces.sh us-south.workspace.central-logging-authorizations.abc12345
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Validate input
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <CENTRAL_WORKSPACE_ID>" >&2
  exit 1
fi

CENTRAL_WS_ID="$1"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in ibmcloud jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Fetch child_workspace_payloads from the central workspace output
# ---------------------------------------------------------------------------
echo "==> Fetching child workspace payloads from central workspace: ${CENTRAL_WS_ID}"

RAW_OUTPUT=$(ibmcloud schematics output --id "${CENTRAL_WS_ID}" --output json 2>/dev/null)

# The Schematics CLI returns an array of output objects.
# child_workspace_payloads is sensitive, so we extract its value field.
PAYLOADS_JSON=$(
  echo "${RAW_OUTPUT}" \
  | jq -r '
      .[]
      | select(.output_name == "child_workspace_payloads")
      | .output_value.value
    '
)

if [[ -z "${PAYLOADS_JSON}" || "${PAYLOADS_JSON}" == "null" ]]; then
  echo "ERROR: Could not find 'child_workspace_payloads' in the central workspace outputs." >&2
  echo "       Make sure the central workspace has been applied successfully." >&2
  exit 1
fi

# The value is a JSON array of JSON-encoded strings (each element is itself a
# JSON string produced by Terraform's jsonencode()). Decode each string.
PAYLOADS_COUNT=$(echo "${PAYLOADS_JSON}" | jq 'length')
echo "==> Found ${PAYLOADS_COUNT} child account(s) to configure."
echo ""

# ---------------------------------------------------------------------------
# Create one Schematics workspace per child account
# ---------------------------------------------------------------------------
CREATED=0
SKIPPED=0

for i in $(seq 0 $((PAYLOADS_COUNT - 1))); do
  # Each element is a JSON string — parse the inner JSON object
  PAYLOAD=$(echo "${PAYLOADS_JSON}" | jq -r ".[$i]" | jq '.')
  WS_NAME=$(echo "${PAYLOAD}" | jq -r '.name')

  echo "-------------------------------------------------------------------"
  echo "  Child account $((i + 1)) / ${PAYLOADS_COUNT}: ${WS_NAME}"
  echo "-------------------------------------------------------------------"

  # Check if a workspace with this name already exists to avoid duplicates
  EXISTING=$(
    ibmcloud schematics workspace list --output json 2>/dev/null \
    | jq -r --arg name "${WS_NAME}" '.workspaces[]? | select(.name == $name) | .id' \
    | head -1
  )

  if [[ -n "${EXISTING}" ]]; then
    echo "  SKIP — workspace '${WS_NAME}' already exists (id: ${EXISTING})"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Create the workspace
  RESULT=$(echo "${PAYLOAD}" | ibmcloud schematics workspace new --file - --output json)
  NEW_WS_ID=$(echo "${RESULT}" | jq -r '.id')
  echo "  CREATED — workspace id: ${NEW_WS_ID}"
  CREATED=$((CREATED + 1))
  echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "==================================================================="
echo "  Done. Created: ${CREATED}  |  Skipped (already existed): ${SKIPPED}"
echo "==================================================================="
echo ""
echo "Next step: run plan + apply on each child workspace."
echo "You can list all workspaces with:"
echo "  ibmcloud schematics workspace list"
echo ""
echo "To plan and apply all child workspaces in sequence, run:"
echo "  ibmcloud schematics workspace list --output json \\"
echo "    | jq -r '.workspaces[] | select(.name | startswith(\"child-logging-\")) | .id' \\"
echo "    | while read -r id; do"
echo "        echo \"Planning \$id ...\""
echo "        ibmcloud schematics plan --id \"\$id\" --force"
echo "      done"
