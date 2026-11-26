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

### 2. IAM user create/delete alerts never arrived

**What happened:** I built an alert chain (EventBridge rule, SNS topic, email).
After `terraform apply` I created and deleted IAM users, but no email arrived.

**Why (two separate causes):**
1. **Wrong region.** IAM is a global service and its events are delivered in
   us-east-1. My rule and SNS topic were in Mumbai (ap-south-1), so the rule
   never saw a `CreateUser` event.
2. **Missing CloudTrail trail.** Even in us-east-1, the rule stayed silent
   until a CloudTrail trail was logging management events. AWS documents that
   a trail must be enabled in the same region as the rule.

**How I found it:** I tested each link of the chain separately:
- Published a test message straight to SNS: the email arrived, so the topic,
  subscription and topic policy were fine.
- Checked the rule and target with `aws events describe-rule` and
  `list-targets-by-rule`: both were correct.
- Checked the rule's `MatchedEvents` metric: empty, so the rule never
  received an event.
- Checked CloudTrail Trails: the list was empty.

**Fix:**
- Added a second Terraform provider (`alias = "use1"`, region us-east-1) and
  moved the SNS topic, rule, target and topic policy to it.
- Added a CloudTrail trail, its S3 log bucket and bucket policy in Terraform.
- Re-tested with a brand-new username: `CreateUser` and `DeleteUser` emails
  both arrived.

**Lesson:** When an alert chain is silent, test each link on its own instead
of guessing. Also, check the cloud provider's docs for global-service
behaviour before assuming a region.

### 3. GitHub Actions could not assume the AWS role (OIDC)

**What happened:** The pipeline failed at the AWS login step with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`, and AWS gave no
reason (CloudTrail showed AccessDenied with null request parameters).

**Why:** My role's trust policy expected the subject `repo:<user>/<repo>:*`,
but GitHub's token carried numeric owner and repo IDs in the subject, so the
pattern never matched.

**How I found it:** I added a temporary workflow step that printed the token's
`sub`, `aud` and `iss` claims and compared them with the trust policy.

**Fix:** Updated the trust policy condition in Terraform to match the exact
subject format, still restricted to my repository. Then removed the debug step.

**Lesson:** When a login fails with no reason, inspect what the other side is
actually sending instead of re-checking what you configured.