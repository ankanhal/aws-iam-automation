"""Offboard a user: remove login, keys, MFA, groups, delete user + secret."""
import logging, sys
import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
iam = boto3.client("iam")
sm = boto3.client("secretsmanager")


def offboard(u):
    try:
        iam.delete_login_profile(UserName=u)
    except iam.exceptions.NoSuchEntityException:
        pass
    for k in iam.list_access_keys(UserName=u)["AccessKeyMetadata"]:
        iam.delete_access_key(UserName=u, AccessKeyId=k["AccessKeyId"])
    for m in iam.list_mfa_devices(UserName=u)["MFADevices"]:
        iam.deactivate_mfa_device(UserName=u, SerialNumber=m["SerialNumber"])
        iam.delete_virtual_mfa_device(SerialNumber=m["SerialNumber"])
    for g in iam.list_groups_for_user(UserName=u)["Groups"]:
        iam.remove_user_from_group(GroupName=g["GroupName"], UserName=u)
    for p in iam.list_attached_user_policies(UserName=u)["AttachedPolicies"]:
        iam.detach_user_policy(UserName=u, PolicyArn=p["PolicyArn"])
    iam.delete_user(UserName=u)
    try:
        sm.delete_secret(SecretId=f"iam/users/{u}", RecoveryWindowInDays=7)
    except sm.exceptions.ResourceNotFoundException:
        pass
    logging.info("OFFBOARDED user=%s", u)


if __name__ == "__main__":
    for user in sys.argv[1:]:
        offboard(user)
