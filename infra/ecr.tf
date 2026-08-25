resource "aws_ecr_repository" "auth" {
  name                 = "${var.project_name}/auth-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true        # allows terraform destroy to remove non-empty repos

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "banking" {
  name                 = "${var.project_name}/banking-service"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lifecycle policy — keep last 10 images, delete older ones to save storage
resource "aws_ecr_lifecycle_policy" "auth" {
  repository = aws_ecr_repository.auth.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "banking" {
  repository = aws_ecr_repository.banking.name
  policy     = aws_ecr_lifecycle_policy.auth.policy   # reuse the same policy
}

output "auth_ecr_url"    { value = aws_ecr_repository.auth.repository_url }
output "banking_ecr_url" { value = aws_ecr_repository.banking.repository_url }