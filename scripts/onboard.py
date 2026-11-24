"""Onboard users from users.csv: create IAM user, add to group,
generate temp password, store it in AWS Secrets Manager."""
import csv, json, logging, secrets, string, sys
import boto3
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
iam = boto3.client("iam")
sm = boto3.client("secretsmanager")


def gen_password(n=16):
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    while True:
        pw = "".join(secrets.choice(chars) for _ in range(n))
        if (any(c.islower() for c in pw) and any(c.isupper() for c in pw)
                and any(c.isdigit() for c in pw) and any(c in "!@#$%^&*" for c in pw)):
            return pw


def onboard(username, group, email):
    try:
        iam.create_user(UserName=username, Tags=[{"Key": "email", "Value": email}])
    except iam.exceptions.EntityAlreadyExistsException:
        logging.warning("%s already exists, skipping", username)
        return
    iam.add_user_to_group(GroupName=group, UserName=username)
    pw = gen_password()
    iam.create_login_profile(UserName=username, Password=pw, PasswordResetRequired=True)
    sm.create_secret(
        Name=f"iam/users/{username}",
        SecretString=json.dumps({"username": username, "password": pw}),
        Tags=[{"Key": "managed-by", "Value": "iam-automation"}],
    )
    logging.info("ONBOARDED user=%s group=%s", username, group)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "users.csv"
    with open(path) as f:
        for row in csv.DictReader(f):
            try:
                onboard(row["username"], row["group"], row["email"])
            except ClientError as e:
                logging.error("FAILED user=%s err=%s", row["username"], e)
