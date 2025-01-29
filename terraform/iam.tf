# REHYDRATION-FARGATE-TASK   #
##############################
resource "aws_iam_role" "rehydration_fargate_task_iam_role" {
  name = "${var.environment_name}-${var.service_name}-fargate-task-role-${data.terraform_remote_state.region.outputs.aws_region_shortname}"
  path = "/service-roles/"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Action": "sts:AssumeRole",
        "Effect": "Allow",
        "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
        }
    }
    ]
}
EOF

}

resource "aws_iam_role_policy_attachment" "rehydration_fargate_iam_role_policy_attachment" {
  role       = aws_iam_role.rehydration_fargate_task_iam_role.id
  policy_arn = aws_iam_policy.rehydration_iam_policy.arn
}

resource "aws_iam_policy" "rehydration_iam_policy" {
  name   = "${var.environment_name}-${var.service_name}-policy-${data.terraform_remote_state.region.outputs.aws_region_shortname}"
  policy = data.aws_iam_policy_document.rehydration_fargate_iam_policy_document.json
}

data "aws_iam_policy_document" "rehydration_fargate_iam_policy_document" {
  statement {
    sid    = "TaskSecretsManagerPermissions"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "secretsmanager:GetSecretValue",
    ]

    resources = [
      data.terraform_remote_state.platform_infrastructure.outputs.docker_hub_credentials_arn,
      data.aws_kms_key.ssm_kms_key.arn,
    ]
  }

  statement {
    sid    = "TaskS3PublishBucketsReadOnly"
    effect = "Allow"

    actions = [
      "s3:Get*",
    ]

    resources = [
      "${data.terraform_remote_state.platform_infrastructure.outputs.sparc_publish50_bucket_arn}/*",
      "${data.terraform_remote_state.platform_infrastructure.outputs.discover_publish50_bucket_arn}/*",
      "${data.terraform_remote_state.platform_infrastructure.outputs.rejoin_publish50_bucket_arn}/*",
      "${data.terraform_remote_state.platform_infrastructure.outputs.precision_publish50_bucket_arn}/*",
      "${data.terraform_remote_state.africa_south_region.outputs.af_south_s3_discover_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "TaskS3RehydrationBuckets"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload"
    ]

    resources = [
      aws_s3_bucket.rehydration_s3_bucket.arn,
      "${aws_s3_bucket.rehydration_s3_bucket.arn}/*",
    ]
  }

  statement {
    sid    = "RehydrationFargateDynamoDBPermissions"
    effect = "Allow"

    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
    ]

    resources = [
      aws_dynamodb_table.idempotency_table.arn,
      "${aws_dynamodb_table.idempotency_table.arn}/*",
      aws_dynamodb_table.tracking_table.arn,
      "${aws_dynamodb_table.tracking_table.arn}/*",
    ]

  }

  statement {
    sid     = "RehydrationFargateSESPermissions"
    effect  = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "TaskLogPermissions"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutDestination",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

# REHYDRATION-LAMBDA   #
##############################

resource "aws_iam_role" "rehydration_lambda_role" {
  name = "${var.environment_name}-${var.service_name}-rehydration_lambda_role-${data.terraform_remote_state.region.outputs.aws_region_shortname}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "rehydration_lambda_iam_policy_attachment" {
  role       = aws_iam_role.rehydration_lambda_role.name
  policy_arn = aws_iam_policy.rehydration_lambda_iam_policy.arn
}

resource "aws_iam_policy" "rehydration_lambda_iam_policy" {
  name   = "${var.environment_name}-${var.service_name}-rehydration-lambda-iam-policy-${data.terraform_remote_state.region.outputs.aws_region_shortname}"
  path   = "/"
  policy = data.aws_iam_policy_document.rehydration_iam_policy_document.json
}

data "aws_iam_policy_document" "rehydration_iam_policy_document" {

  statement {
    sid    = "SecretsManagerPermissions"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "secretsmanager:GetSecretValue",
    ]

    resources = [
      data.terraform_remote_state.platform_infrastructure.outputs.docker_hub_credentials_arn,
      data.aws_kms_key.ssm_kms_key.arn,
    ]
  }

  statement {
    sid     = "RehydrationLambdaPermissions"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutDestination",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ECSTaskPermissions"
    effect  = "Allow"
    actions = [
      "ecs:DescribeTasks",
      "ecs:RunTask",
      "ecs:ListTasks"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ECSPassRole"
    effect  = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      "*"
    ]
  }

  statement {
    sid    = "SSMPermissions"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current_region.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.environment_name}/${var.service_name}/*"
    ]
  }

  statement {
    sid    = "RehydrationLambdaDynamoDBPermissions"
    effect = "Allow"

    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]

    resources = [
      aws_dynamodb_table.idempotency_table.arn,
      "${aws_dynamodb_table.idempotency_table.arn}/*",
      aws_dynamodb_table.tracking_table.arn,
      "${aws_dynamodb_table.tracking_table.arn}/*",
    ]

  }

  statement {
    sid     = "RehydrationLambdaSESPermissions"
    effect  = "Allow"
    actions = [
      "ses:SendEmail",
      "ses:SendRawEmail",
    ]
    resources = ["*"]
  }
}

# EXPIRATION LAMBDA #
#####################
resource "aws_iam_role" "expiration_lambda_role" {
  name = "${var.environment_name}-rehydration-expiration-lambda-role-${data.terraform_remote_state.region.outputs.aws_region_shortname}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": "RehydrationExpirationLambdaAssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "expiration_lambda_iam_policy_attachment" {
  role       = aws_iam_role.expiration_lambda_role.name
  policy_arn = aws_iam_policy.expiration_lambda_iam_policy.arn
}

resource "aws_iam_policy" "expiration_lambda_iam_policy" {
  name   = "${var.environment_name}-rehydration-expiration-lambda-iam-policy-${data.terraform_remote_state.region.outputs.aws_region_shortname}"
  path   = "/"
  policy = data.aws_iam_policy_document.expiration_iam_policy_document.json
}

data "aws_iam_policy_document" "expiration_iam_policy_document" {

  statement {
    sid     = "ExpirationLambdaLogsPermissions"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutDestination",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ExpirationLambdaEC2Permissions"
    effect  = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ExpirationLambdaDynamoDBPermissions"
    effect = "Allow"

    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
    ]

    resources = [
      aws_dynamodb_table.idempotency_table.arn,
      "${aws_dynamodb_table.idempotency_table.arn}/*",
    ]

  }

  statement {
    sid    = "ExpirationLambdaS3RehydrationBuckets"
    effect = "Allow"

    actions = [
      "s3:DeleteObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.rehydration_s3_bucket.arn,
      "${aws_s3_bucket.rehydration_s3_bucket.arn}/*",
    ]
  }

}

# Create Rehydration S3 Bucket Policy #
#######################################
data "aws_iam_policy_document" "rehydration_bucket_iam_policy_document" {

  statement {
    sid       = "AllowPublicObjectAccessToNonRoot"
    effect    = "Allow"
    actions   = ["s3:GetObject*"]
    resources = ["${aws_s3_bucket.rehydration_s3_bucket.arn}/*/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "AllowList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.rehydration_s3_bucket.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

}

