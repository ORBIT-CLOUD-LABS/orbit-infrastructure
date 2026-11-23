# ---------------------------------------------------------------------------
# 기존 계정 모드(use_existing_s3_iam = true):
#   - #10, #11 에서 이미 만든 버킷 2개와 IAM 사용자(orbit-origin-backup, orbit-vault-backup)를 data로 참조
#   - Vault 및 ansible-vault에 이미 저장된 Access Key를 그대로 유지
#   - 펌웨어 버킷 정책만 aws:SourceIp -> aws:SourceVpce 사설 전용으로 전환하고,
#     기존 서비스 사용자에 최소 권한 인라인 정책(s3:DeleteObject 포함)을 보강
# 새 계정 모드(use_existing_s3_iam = false):
#   - 새 버킷 2개(Vault 스냅샷 Object Lock 30일 포함)와 새 IAM 사용자·정책을 처음부터 생성
# ---------------------------------------------------------------------------

data "aws_s3_bucket" "existing_firmware" {
  count  = var.use_existing_s3_iam ? 1 : 0
  bucket = var.firmware_bucket_name
}

data "aws_s3_bucket" "existing_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 1 : 0
  bucket = var.vault_snapshot_bucket_name
}

data "aws_iam_user" "existing_origin" {
  count     = var.use_existing_s3_iam ? 1 : 0
  user_name = var.origin_iam_user_name
}

data "aws_iam_user" "existing_vault_backup" {
  count     = var.use_existing_s3_iam ? 1 : 0
  user_name = var.vault_backup_iam_user_name
}

locals {
  firmware_bucket_id  = var.use_existing_s3_iam ? data.aws_s3_bucket.existing_firmware[0].id : aws_s3_bucket.new_firmware[0].id
  firmware_bucket_arn = var.use_existing_s3_iam ? data.aws_s3_bucket.existing_firmware[0].arn : aws_s3_bucket.new_firmware[0].arn
  vault_bucket_id     = var.use_existing_s3_iam ? data.aws_s3_bucket.existing_vault_snapshot[0].id : aws_s3_bucket.new_vault_snapshot[0].id
  vault_bucket_arn    = var.use_existing_s3_iam ? data.aws_s3_bucket.existing_vault_snapshot[0].arn : aws_s3_bucket.new_vault_snapshot[0].arn

  origin_user_name       = var.use_existing_s3_iam ? data.aws_iam_user.existing_origin[0].user_name : aws_iam_user.new_origin[0].name
  vault_backup_user_name = var.use_existing_s3_iam ? data.aws_iam_user.existing_vault_backup[0].user_name : aws_iam_user.new_vault_backup[0].name
}

# ---------------------------------------------------------------------------
# [새 계정 전용] S3 버킷 2개 및 IAM 사용자 신규 생성 (use_existing_s3_iam = false)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "new_firmware" {
  count         = var.use_existing_s3_iam ? 0 : 1
  bucket        = var.firmware_bucket_name
  force_destroy = var.force_destroy_buckets

  tags = {
    Name      = var.firmware_bucket_name
    Component = "storage"
  }
}

resource "aws_s3_bucket_public_access_block" "new_firmware" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_firmware[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "new_firmware" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_firmware[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "new_firmware" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_firmware[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "new_firmware" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_firmware[0].id

  rule {
    id     = "firmware-noncurrent-expire-30d"
    status = "Enabled"
    filter {
      prefix = "firmware/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "firmware-abort-multipart-7d"
    status = "Enabled"
    filter {
      prefix = "firmware/"
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket" "new_vault_snapshot" {
  count               = var.use_existing_s3_iam ? 0 : 1
  bucket              = var.vault_snapshot_bucket_name
  object_lock_enabled = var.enable_vault_object_lock
  force_destroy       = var.force_destroy_buckets

  tags = {
    Name      = var.vault_snapshot_bucket_name
    Component = "storage"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "new_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : (var.enable_vault_object_lock ? 1 : 0)
  bucket = aws_s3_bucket.new_vault_snapshot[0].id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 30
    }
  }
}

resource "aws_s3_bucket_versioning" "new_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : (var.enable_vault_object_lock ? 0 : 1)
  bucket = aws_s3_bucket.new_vault_snapshot[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "new_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_vault_snapshot[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "new_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_vault_snapshot[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "new_vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = aws_s3_bucket.new_vault_snapshot[0].id

  rule {
    id     = "vault-snapshot-lifecycle"
    status = "Enabled"
    filter {
      prefix = "vault/"
    }
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_user" "new_origin" {
  count = var.use_existing_s3_iam ? 0 : 1
  name  = var.origin_iam_user_name
  tags  = { Component = "storage" }
}

resource "aws_iam_user" "new_vault_backup" {
  count = var.use_existing_s3_iam ? 0 : 1
  name  = var.vault_backup_iam_user_name
  tags  = { Component = "storage" }
}

# ---------------------------------------------------------------------------
# [공통 적용] 사설 전용 버킷 정책(aws:SourceVpce) 및 최소 권한 서비스 IAM 정책
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "firmware" {
  count  = var.enable_s3_vpce ? 1 : 0
  bucket = local.firmware_bucket_id

  # 기존 계정의 aws:SourceIp 정책을 제거하고, S3 VPC 엔드포인트(aws:SourceVpce) 경유 읽기만 허용
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.firmware_bucket_arn, "${local.firmware_bucket_arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "AllowEdgeReadFromVpceOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${local.firmware_bucket_arn}/firmware/*"
        Condition = {
          StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3_interface[0].id }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "vault_snapshot" {
  count  = var.use_existing_s3_iam ? 0 : 1
  bucket = local.vault_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.vault_bucket_arn, "${local.vault_bucket_arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_iam_user_policy" "origin" {
  name = "OrbitOriginFirmwarePolicy"
  user = local.origin_user_name

  # orbit-server#128 보상 삭제 요건(s3:DeleteObject) 포함, 버전 삭제(s3:DeleteObjectVersion) 제외
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListFirmwarePrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.firmware_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["firmware", "firmware/", "firmware/*"] }
        }
      },
      {
        Sid      = "ReadWriteDeleteFirmwareCurrentVersion"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.firmware_bucket_arn}/firmware/*"
      },
      {
        Sid      = "GetBucketLocation"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = local.firmware_bucket_arn
      }
    ]
  })
}

resource "aws_iam_user_policy" "vault_backup" {
  count = var.use_existing_s3_iam ? 0 : 1
  name  = "OrbitVaultSnapshotBackupPolicy"
  user  = local.vault_backup_user_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListVaultPrefix"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.vault_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["vault", "vault/", "vault/*"] }
        }
      },
      {
        Sid      = "ReadWriteVaultSnapshots"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${local.vault_bucket_arn}/vault/*"
      },
      {
        Sid      = "GetBucketLocation"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = local.vault_bucket_arn
      }
    ]
  })
}

# 관리자 노트북 SSM 포트 포워딩 최소 권한 정책
resource "aws_iam_policy" "admin_ssm_port_forward" {
  count = var.enable_admin_jump ? 1 : 0
  name  = "OrbitAdminSsmPortForwardPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPortForwardingSessionToJumpOnly"
        Effect = "Allow"
        Action = "ssm:StartSession"
        Resource = [
          aws_instance.admin_jump[0].arn,
          "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSessionToRemoteHost"
        ]
      },
      {
        Sid      = "AllowTerminateOwnSession"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession"]
        Resource = "arn:aws:ssm:${var.aws_region}:*:session/$${aws:username}-*"
      }
    ]
  })
}
