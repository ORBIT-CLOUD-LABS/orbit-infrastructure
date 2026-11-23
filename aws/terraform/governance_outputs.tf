data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 보안·감사 기본선: GuardDuty + IAM Access Analyzer + CloudTrail(전 리전·무결성 검증)
# ---------------------------------------------------------------------------
resource "aws_guardduty_detector" "this" {
  count  = var.enable_security_baseline ? 1 : 0
  enable = true
}

resource "aws_accessanalyzer_analyzer" "this" {
  count         = var.enable_security_baseline ? 1 : 0
  analyzer_name = "orbit-account-analyzer"
  type          = "ACCOUNT"
}

resource "aws_s3_bucket" "cloudtrail" {
  count  = var.enable_security_baseline && var.cloudtrail_bucket_name != "" ? 1 : 0
  bucket = var.cloudtrail_bucket_name

  tags = {
    Name      = var.cloudtrail_bucket_name
    Component = "security"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count  = var.enable_security_baseline && var.cloudtrail_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = var.enable_security_baseline && var.cloudtrail_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = var.enable_security_baseline && var.cloudtrail_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail[0].arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cloudtrail[0].arn, "${aws_s3_bucket.cloudtrail[0].arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_cloudtrail" "this" {
  count = var.enable_security_baseline && var.cloudtrail_bucket_name != "" ? 1 : 0

  name                          = "orbit-account-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ---------------------------------------------------------------------------
# CloudWatch VPN TunnelState 알람 + AWS Budgets 알람
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  count = var.budget_alert_email != "" ? 1 : 0
  name  = "orbit-aws-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.budget_alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_cloudwatch_metric_alarm" "vpn_tunnel1_down" {
  count = var.enable_vpn ? 1 : 0

  alarm_name          = "orbit-vpn-tunnel1-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "ORBIT Site-to-Site VPN Tunnel 1 is DOWN"

  dimensions = {
    VpnId           = aws_vpn_connection.onprem[0].id
    TunnelIpAddress = aws_vpn_connection.onprem[0].tunnel1_address
  }

  alarm_actions = var.budget_alert_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}

resource "aws_budgets_budget" "monthly" {
  count = var.budget_alert_email != "" ? 1 : 0

  name         = "orbit-${var.environment}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts[0].arn]
  }
}

# ---------------------------------------------------------------------------
# Outputs (VPN PSK는 민감값 처리)
# ---------------------------------------------------------------------------
output "vpc_id" {
  description = "orbit-vpc ID"
  value       = aws_vpc.orbit.id
}

output "rds_endpoint" {
  description = "RDS 엔드포인트 (호스트:포트)"
  value       = aws_db_instance.orbit.endpoint
}

output "orbit_server_db_url" {
  description = "orbit-server에 주입할 JDBC DB_URL (TLS 연결 포함)"
  value       = "jdbc:mysql://${aws_db_instance.orbit.endpoint}/${var.db_name}?sslMode=REQUIRED"
}

output "s3_vpce_id" {
  description = "S3 인터페이스 엔드포인트 ID"
  value       = var.enable_s3_vpce ? aws_vpc_endpoint.s3_interface[0].id : null
}

output "s3_vpce_dns_entries" {
  description = "온프레미스 서버·Edge에서 연결할 S3 인터페이스 엔드포인트 DNS 목록"
  value       = var.enable_s3_vpce ? aws_vpc_endpoint.s3_interface[0].dns_entry : null
}

output "admin_jump_instance_id" {
  description = "관리자 SSM 포트 포워딩 대상 admin-jump 인스턴스 ID"
  value       = var.enable_admin_jump ? aws_instance.admin_jump[0].id : null
}

output "vpn_tunnel1_address" {
  description = "strongSwan 설정용 AWS VPN 터널 1 외부 IP (민감값)"
  value       = var.enable_vpn ? aws_vpn_connection.onprem[0].tunnel1_address : null
  sensitive   = true
}

output "vpn_tunnel2_address" {
  description = "strongSwan 설정용 AWS VPN 터널 2 외부 IP (민감값)"
  value       = var.enable_vpn ? aws_vpn_connection.onprem[0].tunnel2_address : null
  sensitive   = true
}

output "vpn_tunnel1_preshared_key" {
  description = "strongSwan 설정용 터널 1 PSK (민감값)"
  value       = var.enable_vpn ? aws_vpn_connection.onprem[0].tunnel1_preshared_key : null
  sensitive   = true
}

output "vpn_tunnel2_preshared_key" {
  description = "strongSwan 설정용 터널 2 PSK (민감값)"
  value       = var.enable_vpn ? aws_vpn_connection.onprem[0].tunnel2_preshared_key : null
  sensitive   = true
}
