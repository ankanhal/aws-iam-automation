terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # Remote state: S3 for storage, DynamoDB for locking
  backend "s3" {
    bucket         = "ankan-tfstate-2026"
    key            = "iam-automation/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

# IAM events are delivered to us-east-1, so audit resources use this provider
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

variable "region" {
  default = "ap-south-1"
}

# group name -> list of managed policy ARNs (least privilege)
variable "groups" {
  type = map(list(string))
  default = {
    dev      = ["arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"]
    ops      = ["arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess", "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
    readonly = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  }
}

resource "aws_iam_group" "this" {
  for_each = var.groups
  name     = each.key
}

locals {
  attachments = merge([
    for g, arns in var.groups : {
      for arn in arns : "${g}|${arn}" => { group = g, arn = arn }
    }
  ]...)
}

resource "aws_iam_group_policy_attachment" "this" {
  for_each   = local.attachments
  group      = aws_iam_group.this[each.value.group].name
  policy_arn = each.value.arn
}

# Strong password rules (note: this does not enforce MFA)
resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length      = 14
  require_symbols              = true
  require_numbers              = true
  require_uppercase_characters = true
  require_lowercase_characters = true
  max_password_age             = 90
  password_reuse_prevention    = 5
}

# Audit: EventBridge rule -> SNS email alert (all in us-east-1)
resource "aws_sns_topic" "iam_alerts" {
  provider = aws.use1
  name     = "iam-user-changes"
}

resource "aws_cloudwatch_event_rule" "iam_changes" {
  provider = aws.use1
  name     = "iam-user-create-delete"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail        = { eventName = ["CreateUser", "DeleteUser"] }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  provider = aws.use1
  rule     = aws_cloudwatch_event_rule.iam_changes.name
  arn      = aws_sns_topic.iam_alerts.arn
}

resource "aws_sns_topic_policy" "allow_events" {
  provider = aws.use1
  arn      = aws_sns_topic.iam_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.iam_alerts.arn
    }]
  })
}

# CloudTrail: required for IAM events to reach EventBridge
data "aws_caller_identity" "current" {}

locals {
  trail_name = "iam-audit-trail"
  trail_arn  = "arn:aws:cloudtrail:us-east-1:${data.aws_caller_identity.current.account_id}:trail/iam-audit-trail"
}

resource "aws_s3_bucket" "trail_logs" {
  provider      = aws.use1
  bucket        = "ankan-iam-audit-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # lets terraform destroy remove it on cleanup
}

resource "aws_s3_bucket_public_access_block" "trail_logs" {
  provider                = aws.use1
  bucket                  = aws_s3_bucket.trail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail_logs.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "trail_logs" {
  provider = aws.use1
  bucket   = aws_s3_bucket.trail_logs.id
  policy   = data.aws_iam_policy_document.trail_bucket.json
}

resource "aws_cloudtrail" "iam_audit" {
  provider                      = aws.use1
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.trail_logs]
}