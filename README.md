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
