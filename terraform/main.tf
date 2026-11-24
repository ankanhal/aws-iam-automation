terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  #Enable after creating the S3 bucket + DynamoDB table:
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

# Force MFA-friendly strong password policy
resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length      = 14
  require_symbols              = true
  require_numbers              = true
  require_uppercase_characters = true
  require_lowercase_characters = true
  max_password_age             = 90
  password_reuse_prevention    = 5
}

# Audit: CloudTrail + SNS alerts
resource "aws_sns_topic" "iam_alerts" {
  name = "iam-user-changes"
}

resource "aws_cloudwatch_event_rule" "iam_changes" {
  name = "iam-user-create-delete"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail        = { eventName = ["CreateUser", "DeleteUser"] }
  })
}

resource "aws_cloudwatch_event_target" "sns" {
  rule = aws_cloudwatch_event_rule.iam_changes.name
  arn  = aws_sns_topic.iam_alerts.arn
}

resource "aws_sns_topic_policy" "allow_events" {
  arn = aws_sns_topic.iam_alerts.arn
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
