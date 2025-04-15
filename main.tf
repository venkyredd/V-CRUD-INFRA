provider "aws" {
  region = "us-east-1"
}

# Get Availability Zones
data "aws_availability_zones" "available" {}

# VPC
resource "aws_vpc" "v_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "v-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "v_igw" {
  vpc_id = aws_vpc.v_vpc.id
  tags = {
    Name = "v-igw"
  }
}

# Public Subnets
resource "aws_subnet" "v_public" {
  count                   = 2
  vpc_id                  = aws_vpc.v_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.v_vpc.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "v-public-${count.index}"
  }
}

# Private Subnets
resource "aws_subnet" "v_private" {
  count             = 2
  vpc_id            = aws_vpc.v_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.v_vpc.cidr_block, 8, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = {
    Name = "v-private-${count.index}"
  }
}

# Public Route Table
resource "aws_route_table" "v_public_rt" {
  vpc_id = aws_vpc.v_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.v_igw.id
  }
  tags = {
    Name = "v-public-rt"
  }
}

# Associate Public Subnets
resource "aws_route_table_association" "v_public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.v_public[count.index].id
  route_table_id = aws_route_table.v_public_rt.id
}

# Security Group
resource "aws_security_group" "v_sg" {
  name   = "v-sg"
  vpc_id = aws_vpc.v_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "v-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "v_alb" {
  name               = "v-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.v_sg.id]
  subnets            = aws_subnet.v_public[*].id

  tags = {
    Name = "v-alb"
  }
}

# Target Group
resource "aws_lb_target_group" "v_tg" {
  name        = "v-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.v_vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "v-tg"
  }
}

# Listener
resource "aws_lb_listener" "v_listener" {
  load_balancer_arn = aws_lb.v_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.v_tg.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "v_cluster" {
  name = "v-cluster"
}

# IAM Role for ECS Tasks
resource "aws_iam_role" "v_task_exec_role" {
  name = "v-task-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "v_task_exec_policy" {
  role       = aws_iam_role.v_task_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "v_log_group" {
  name              = "/ecs/v-app"
  retention_in_days = 7
}

# ECS Task Definition
resource "aws_ecs_task_definition" "v_task_def" {
  family                   = "v-task"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.v_task_exec_role.arn

  container_definitions = jsonencode([{
    name      = "v-container"
    image     = var.image_url # <-- use TF var, pass it via GitHub secrets
    essential = true
    portMappings = [{
      containerPort = 80,
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        awslogs-group         = aws_cloudwatch_log_group.v_log_group.name,
        awslogs-region        = "us-east-1",
        awslogs-stream-prefix = "v"
      }
    }
  }])
}

# ECS Service
resource "aws_ecs_service" "v_service" {
  name            = "v-service"
  cluster         = aws_ecs_cluster.v_cluster.id
  launch_type     = "FARGATE"
  task_definition = aws_ecs_task_definition.v_task_def.arn
  desired_count   = 1

  network_configuration {
    subnets         = aws_subnet.v_private[*].id
    security_groups = [aws_security_group.v_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.v_tg.arn
    container_name   = "v-container"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.v_listener]
}

# Variables
variable "image_url" {
  description = "Docker image URL for ECS Task"
  type        = string
}

# Outputs
output "alb_dns_name" {
  value = aws_lb.v_alb.dns_name
}
