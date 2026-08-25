variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "project_name" {
  type    = string
  default = "jdbank"
}

# Database passwords — we'll generate these and store in Secrets Manager
variable "db_master_password_auth" {
  type      = string
  sensitive = true
}

variable "db_master_password_banking" {
  type      = string
  sensitive = true
}