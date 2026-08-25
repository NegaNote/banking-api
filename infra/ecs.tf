resource "aws_cloudwatch_log_group" "auth" {
  name              = "/ecs/${var.project_name}/auth-service"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "banking" {
  name              = "/ecs/${var.project_name}/banking-service"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "auth" {
  family                   = "${var.project_name}-auth-service"
  network_mode             = "awsvpc"      # required for Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"          # 0.25 vCPU
  memory                   = "512"          # 512 MB

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "auth-service"
    image     = "${aws_ecr_repository.auth.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8081
      protocol      = "tcp"
    }]

    environment = [
      { name = "SPRING_PROFILES_ACTIVE",      value = "docker" },
      { name = "SPRING_DATASOURCE_URL",       value = "jdbc:mysql://${aws_db_instance.auth.endpoint}/authdb?useSSL=false&serverTimezone=UTC" },
      { name = "SPRING_DATASOURCE_USERNAME",  value = "authadmin" },
      { name = "APP_JWT_KEY_ID",              value = "auth-key-1" },
      { name = "APP_JWT_EXPIRATION_MS",       value = "3600000" },
      { name = "APP_AUTH_JWKS_URI",           value = "http://${aws_lb.main.dns_name}/.well-known/jwks.json" },
    ]

    secrets = [
      { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = aws_secretsmanager_secret.db_auth_password.arn },
      { name = "APP_JWT_PRIVATE_KEY",        valueFrom = aws_secretsmanager_secret.jwt_private_key.arn },
      { name = "APP_JWT_PUBLIC_KEY",         valueFrom = aws_secretsmanager_secret.jwt_public_key.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.auth.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "auth"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -q --spider http://localhost:8081/actuator/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

resource "aws_ecs_task_definition" "banking" {
  family                   = "${var.project_name}-banking-service"
  network_mode             = "awsvpc"      # required for Fargate
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"          # 0.25 vCPU
  memory                   = "512"          # 512 MB

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "banking-service"
    image     = "${aws_ecr_repository.banking.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [
      { name = "SPRING_PROFILES_ACTIVE",      value = "docker" },
      { name = "SPRING_DATASOURCE_URL",       value = "jdbc:mysql://${aws_db_instance.banking.endpoint}/bankdb?useSSL=false&serverTimezone=UTC" },
      { name = "SPRING_DATASOURCE_USERNAME",  value = "bankadmin" },
      { name = "APP_JWT_KEY_ID",              value = "banking-key-1" },
      { name = "APP_JWT_EXPIRATION_MS",       value = "3600000" },
      { name = "APP_AUTH_JWKS_URI",           value = "http://${aws_lb.main.dns_name}/.well-known/jwks.json" },
    ]

    secrets = [
      { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = aws_secretsmanager_secret.db_banking_password.arn },
      { name = "APP_JWT_PRIVATE_KEY",        valueFrom = aws_secretsmanager_secret.jwt_private_key.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.banking.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "banking"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget -q --spider http://localhost:8080/actuator/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

resource "aws_ecs_service" "auth" {
  name            = "auth-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.auth.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.services.id]
    assign_public_ip = true   # public subnets — needed to pull from ECR and reach Secrets Manager
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.auth.arn
    container_name   = "auth-service"
    container_port   = 8081
  }

  depends_on = [aws_lb_listener.http]
}

resource "aws_ecs_service" "banking" {
  name            = "banking-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.banking.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.services.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.banking.arn
    container_name   = "banking-service"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.http]
}