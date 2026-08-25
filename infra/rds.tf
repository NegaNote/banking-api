# DB subnet group: RDS requires this to know which subnets it can run in
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

# Auth-db
resource "aws_db_instance" "auth" {
  identifier             = "${var.project_name}-auth-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t4g.micro"   # cheap, ARM-based
  allocated_storage      = 20
  storage_type           = "gp3"

  db_name                = "authdb"
  username               = "authadmin"
  password               = var.db_master_password_auth

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.databases.id]

  publicly_accessible    = false
  skip_final_snapshot    = true    # for learning; production = false
  deletion_protection    = false   # for learning; production = true

  backup_retention_period = 0      # disable automated backups for dev
}

# Banking-db
resource "aws_db_instance" "banking" {
  identifier             = "${var.project_name}-banking-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp3"

  db_name                = "bankdb"
  username               = "bankadmin"
  password               = var.db_master_password_banking

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.databases.id]

  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  backup_retention_period = 0
}

output "auth_db_endpoint"    { value = aws_db_instance.auth.endpoint }
output "banking_db_endpoint" { value = aws_db_instance.banking.endpoint }