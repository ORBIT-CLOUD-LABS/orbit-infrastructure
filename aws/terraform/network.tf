# ---------------------------------------------------------------------------
# orbit-vpc (10.20.0.0/16): IGW · NAT · 퍼블릭 서브넷 없음, DNS 지원/호스트 이름 켬
# ---------------------------------------------------------------------------
resource "aws_vpc" "orbit" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "orbit-vpc"
    Component = "network"
  }
}

# 가용 영역 2a: 모든 리소스(RDS, admin-jump, SSM VPCE x3, S3 VPCE) 배치
resource "aws_subnet" "private_2a" {
  vpc_id            = aws_vpc.orbit.id
  cidr_block        = var.subnet_2a_cidr
  availability_zone = "ap-northeast-2a"

  tags = {
    Name      = "orbit-private-2a"
    Component = "network"
  }
}

# 가용 영역 2c: 비어 있음 (RDS 서브넷 그룹 orbit-db-subnets의 2a + 2c 필수 요건 충족용)
resource "aws_subnet" "private_2c" {
  vpc_id            = aws_vpc.orbit.id
  cidr_block        = var.subnet_2c_cidr
  availability_zone = "ap-northeast-2c"

  tags = {
    Name      = "orbit-private-2c"
    Component = "network"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.orbit.id

  tags = {
    Name      = "rt-private"
    Component = "network"
  }
}

resource "aws_route_table_association" "private_2a" {
  subnet_id      = aws_subnet.private_2a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2c" {
  subnet_id      = aws_subnet.private_2c.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Site-to-Site VPN: VGW (ASN 64512) + CGW + IPsec 터널 x2 (IKEv2 / AES-256 / SHA-256 / DH 14+)
# ---------------------------------------------------------------------------
resource "aws_customer_gateway" "onprem" {
  count = var.enable_vpn ? 1 : 0

  bgp_asn    = 65000
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = {
    Name      = "orbit-fw-cgw"
    Component = "network"
  }
}

resource "aws_vpn_gateway" "this" {
  count = var.enable_vpn ? 1 : 0

  vpc_id          = aws_vpc.orbit.id
  amazon_side_asn = var.vgw_asn

  tags = {
    Name      = "orbit-vgw"
    Component = "network"
  }
}

resource "aws_vpn_gateway_route_propagation" "private" {
  count = var.enable_vpn ? 1 : 0

  vpn_gateway_id = aws_vpn_gateway.this[0].id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpn_connection" "onprem" {
  count = var.enable_vpn ? 1 : 0

  vpn_gateway_id      = aws_vpn_gateway.this[0].id
  customer_gateway_id = aws_customer_gateway.onprem[0].id
  type                = "ipsec.1"
  static_routes_only  = true

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14, 15, 16, 17, 18]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14, 15, 16, 17, 18]

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14, 15, 16, 17, 18]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14, 15, 16, 17, 18]

  tags = {
    Name      = "orbit-s2s-vpn"
    Component = "network"
  }
}

resource "aws_vpn_connection_route" "onprem" {
  count = var.enable_vpn ? 1 : 0

  destination_cidr_block = var.onprem_cidr
  vpn_connection_id      = aws_vpn_connection.onprem[0].id
}

# ---------------------------------------------------------------------------
# S3 인터페이스 엔드포인트 (2a 단독 배치로 비용 절감, Private DNS 켬, 아웃바운드 없음)
# ---------------------------------------------------------------------------
resource "aws_security_group" "s3_vpce" {
  count = var.enable_s3_vpce ? 1 : 0

  name        = "orbit-s3-vpce-sg"
  description = "443 from on-prem via VPN (no outbound rules)"
  vpc_id      = aws_vpc.orbit.id

  ingress {
    description = "HTTPS from on-prem network"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.onprem_cidr]
  }

  tags = {
    Name      = "orbit-s3-vpce-sg"
    Component = "network"
  }
}

resource "aws_vpc_endpoint" "s3_interface" {
  count = var.enable_s3_vpce ? 1 : 0

  vpc_id              = aws_vpc.orbit.id
  service_name        = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_2a.id]
  security_group_ids  = [aws_security_group.s3_vpce[0].id]
  private_dns_enabled = true

  # Gateway 엔드포인트 없이 S3 Interface 엔드포인트 단독으로 Private DNS를 켜기 위한 설정
  dns_options {
    private_dns_only_for_inbound_resolver_endpoint = false
  }

  # 엔드포인트 정책: 우리 프로젝트의 버킷 2개만 통과 허용
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowOnlyOrbitBuckets"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          local.firmware_bucket_arn,
          "${local.firmware_bucket_arn}/*",
          local.vault_bucket_arn,
          "${local.vault_bucket_arn}/*"
        ]
      }
    ]
  })

  tags = {
    Name      = "orbit-s3-vpce"
    Component = "network"
  }
}

# ---------------------------------------------------------------------------
# 관리자 SSM 포트 포워딩: admin-jump EC2 (t4g.nano, IMDSv2) + SSM 인터페이스 엔드포인트 x3
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023_arm64" {
  count = var.enable_admin_jump ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

resource "aws_security_group" "admin_jump" {
  count = var.enable_admin_jump ? 1 : 0

  name        = "admin-jump-sg"
  description = "No inbound; outbound 443 to SSM VPCE and 3306 to RDS only"
  vpc_id      = aws_vpc.orbit.id

  tags = {
    Name      = "admin-jump-sg"
    Component = "compute"
  }
}

resource "aws_security_group" "ssm_vpce" {
  count = var.enable_admin_jump ? 1 : 0

  name        = "orbit-ssm-vpce-sg"
  description = "443 from admin-jump-sg only (no outbound rules)"
  vpc_id      = aws_vpc.orbit.id

  ingress {
    description     = "HTTPS from admin-jump EC2"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.admin_jump[0].id]
  }

  tags = {
    Name      = "orbit-ssm-vpce-sg"
    Component = "network"
  }
}

resource "aws_security_group_rule" "jump_to_ssm" {
  count = var.enable_admin_jump ? 1 : 0

  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.admin_jump[0].id
  source_security_group_id = aws_security_group.ssm_vpce[0].id
}

locals {
  ssm_endpoints = var.enable_admin_jump ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = local.ssm_endpoints

  vpc_id              = aws_vpc.orbit.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_2a.id]
  security_group_ids  = [aws_security_group.ssm_vpce[0].id]
  private_dns_enabled = true

  tags = {
    Name      = "orbit-${each.key}-vpce"
    Component = "network"
  }
}

resource "aws_iam_role" "admin_jump" {
  count = var.enable_admin_jump ? 1 : 0
  name  = "orbit-admin-jump-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Component = "compute"
  }
}

resource "aws_iam_role_policy_attachment" "admin_jump_ssm" {
  count      = var.enable_admin_jump ? 1 : 0
  role       = aws_iam_role.admin_jump[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "admin_jump" {
  count = var.enable_admin_jump ? 1 : 0
  name  = "orbit-admin-jump-profile"
  role  = aws_iam_role.admin_jump[0].name
}

resource "aws_instance" "admin_jump" {
  count = var.enable_admin_jump ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64[0].value
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.private_2a.id
  vpc_security_group_ids      = [aws_security_group.admin_jump[0].id]
  iam_instance_profile        = aws_iam_instance_profile.admin_jump[0].name
  associate_public_ip_address = false

  # IMDSv2 강제 (구성도 명시 사항)
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name      = "admin-jump"
    Component = "compute"
  }
}
