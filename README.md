# IAM Automation (AWS)

Terraform: groups, least-privilege policies, password policy, audit alerts.
Python (boto3): ticket-style user onboarding/offboarding with creds in Secrets Manager.

## Run
    cd terraform && terraform init && terraform apply
    cd ../scripts && pip install -r requirements.txt
    python onboard.py users.csv
    python offboard.py asha.k

## Notes
- Enable CloudTrail in the account so the EventBridge rule fires.
- Subscribe your email to the SNS topic `iam-user-changes`.
- Use OIDC role for GitHub Actions; never commit AWS keys.
- Use a sandbox AWS account and set a billing alert.

## Problems I faced

### 1. Re-onboarding a user fails within 7 days of offboarding
 
[Error when re-onboarding a user](docs/images/onboard-error.png)

**What happened:** After offboarding a user and onboarding the same username
again, the script failed on the Secrets Manager step with an error saying the
secret is scheduled for deletion.

**Why:** `offboard.py` calls `delete_secret` with a 7-day recovery window, so
the secret `iam/users/<username>` still exists in a "pending deletion" state.
`onboard.py` then calls `create_secret` with the same name, which AWS rejects.

**How I found it:** I tested the full cycle (onboard, offboard, onboard) and
read the error from boto3.

**Current status:** Known issue. Workaround: force-delete the secret with
`aws secretsmanager delete-secret --secret-id iam/users/<name>
--force-delete-without-recovery`.

**Planned fix:** In `onboard.py`, catch the error, call `restore_secret`, then
`put_secret_value` with the new password. A 7-day recovery window is kept
on purpose, so an accidental offboarding can be undone.