# Validation — confirming logs are generated and routed correctly

Run this after `central/` and every `child/` workspace have applied successfully. It confirms the S2S authorizations exist, the routing resources are correctly configured, and audit events / platform logs actually arrive at the central IBM Cloud Logs instance.

Replace the placeholders before running any command:

| Placeholder | Where to find it |
|---|---|
| `<CENTRAL_ACCOUNT_ID>` | `central/` output `central_account_id` |
| `<CENTRAL_LOGS_INSTANCE_GUID>` | `central/` output `central_logs_instance_guid` |
| `<CENTRAL_LOGS_CRN>` | `central/` output `central_logs_crn` |
| `<CHILD_ACCOUNT_ID>` | `central/` output `child_accounts`, or the account you deployed a `child/` workspace into |

---

## 1. Confirm the S2S authorizations exist (central account)

```bash
ibmcloud target -c <CENTRAL_ACCOUNT_ID>

ibmcloud iam authorization-policies --output json \
  | jq -r '.[] | [(.subjects[0].attributes[] | select(.name=="serviceName") | .value),
                  (.subjects[0].attributes[] | select(.name=="accountId")   | .value),
                  .roles[0].display_name] | @tsv' | sort
```

For each child account you expect to see two rows — one `logs-router`, one `atracker` — both granting role `Sender`.

## 2. Confirm the routing resources exist (child account)

```bash
ibmcloud target -c <CHILD_ACCOUNT_ID>

ibmcloud atracker target ls
ibmcloud atracker route ls
ibmcloud logs-router target list
ibmcloud logs-router route list
```

Check:
- The Activity Tracker target's CRN matches `<CENTRAL_LOGS_CRN>`.
- The Activity Tracker route has `locations: ["*"]`.
- Both the Logs Routing target and route show `managed_by: enterprise`.

## 3. Generate a test signal in the child account

- **Audit event (Activity Tracker):** almost any IAM/API call generates one — for example:
  ```bash
  ibmcloud resource groups
  ```
  or create/update/delete a small resource. Note the exact time so you can find it later.
- **Platform log (Logs Routing):** trigger activity in a service that emits platform logs (create/delete a small resource works). Platform log volume is usually much higher than audit events, so normal account activity will surface it without a deliberate trigger.

## 4. Check arrival in the central IBM Cloud Logs instance

```bash
ibmcloud target -c <CENTRAL_ACCOUNT_ID>
```

Open the **IBM Cloud Logs** dashboard for instance `<CENTRAL_LOGS_INSTANCE_GUID>` (Console → Observability → Logging → your instance) and search for:
- The child account ID (`<CHILD_ACCOUNT_ID>`) — should appear as a field on incoming log records.
- The specific action taken in step 3 (e.g. the resource name, or the IAM action name).

Allow **a few minutes** for records to appear — routing is not instant, especially right after a target/route was just created.

## 5. If nothing shows up after ~10-15 minutes

- Re-check step 1 — a missing or wrong-service authorization is the most common cause of silently dropped logs.
- Re-check that the target CRN in step 2 matches the instance in step 4 exactly (account ID **and** GUID).
- Check the Logs Routing target's write/health status (`ibmcloud logs-router target list`) — a bad status usually means the authorization isn't effective yet, even if the Terraform apply succeeded.

---

## Next step

Once both audit events and platform logs are confirmed arriving for every child account, apply the IAM Action Control guardrails described in [RUNBOOK.md](RUNBOOK.md#step-5--apply-iam-guardrails-after-all-accounts-validated) to lock down the enterprise-managed routes.
