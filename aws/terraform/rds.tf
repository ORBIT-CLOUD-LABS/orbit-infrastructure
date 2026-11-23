# ---------------------------------------------------------------------------
# RDS 인스턴스 (vehicle DB): 사설 전용, 퍼블릭 접근 off, TLS 강제, 아웃바운드 규칙 없음
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "orbit" {
  name       = "orbit-db-subnets"
  subnet_ids = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]

  tags = {
    Name      = "orbit-db-subnets"
    Component = "database"
  }
}

resource "aws_security_group" "rds" {
  name        = "orbit-rds-sg"
  description = "MySQL 3306 from on-prem clusters and admin-jump-sg only (no outbound rules)"
  vpc_id      = aws_vpc.orbit.id

  ingress {
    description = "MySQL from on-prem cluster nodes via VPN"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.onprem_rds_cidrs
  }

  dynamic "ingress" {
    for_each = var.enable_admin_jump ? [1] : []
    content {
      description     = "MySQL from admin-jump SSM port-forwarding instance"
      from_port       = 3306
      to_port         = 3306
      protocol        = "tcp"
      security_groups = [aws_security_group.admin_jump[0].id]
    }
  }

  tags = {
    Name      = "orbit-rds-sg"
    Component = "database"
  }
}

resource "aws_security_group_rule" "jump_to_rds" {
  count = var.enable_admin_jump ? 1 : 0

  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.admin_jump[0].id
  source_security_group_id = aws_security_group.rds.id
}

resource "aws_db_parameter_group" "mysql8" {
  name   = "orbit-mysql8-tls"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_0900_ai_ci"
  }

  # TLS 암호화 연결 강제 (구성도 요구사항)
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  tags = {
    Name      = "orbit-mysql8-tls"
    Component = "database"
  }
}

resource "aws_db_instance" "orbit" {
  identifier     = "orbit-vehicle-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.orbit.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.mysql8.name

  publicly_accessible     = false
  multi_az                = var.db_multi_az
  backup_retention_period = 7

  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name      = "orbit-vehicle-mysql"
    Component = "database"
  }
}
