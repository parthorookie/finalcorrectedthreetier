# RabbitMQ Security Group
resource "aws_security_group" "rabbitmq" {
  name        = "${var.project_name}-${var.environment}-rabbitmq"
  description = "RabbitMQ security group for ${var.project_name}-${var.environment}"
  vpc_id      = var.vpc_id

  # AMQP port - Used by backend and worker applications
  ingress {
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
    description     = "RabbitMQ AMQP from EKS nodes"
  }

  # Management UI (RabbitMQ Dashboard) - From EKS nodes
  ingress {
    from_port       = 15672
    to_port         = 15672
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
    description     = "RabbitMQ Management UI from EKS nodes"
  }

  # Management UI - From your operator IP (for browser access)
  ingress {
    from_port   = 15672
    to_port     = 15672
    protocol    = "tcp"
    cidr_blocks = [var.operator_ip_cidr]
    description = "RabbitMQ Management UI from operator IP"
  }

  # Prometheus metrics exporter
  ingress {
    from_port       = 15692
    to_port         = 15692
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
    description     = "Prometheus metrics from EKS nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-rabbitmq-sg"
    Environment = var.environment
  }
}

# ── IAM Role ──────────────────────────────────────────────────────────────────
resource "aws_iam_role" "rabbitmq_ec2" {
  name = "${var.project_name}-rabbitmq-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rabbitmq_ssm" {
  role       = aws_iam_role.rabbitmq_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "rabbitmq" {
  name = "${var.project_name}-rabbitmq-profile"
  role = aws_iam_role.rabbitmq_ec2.name
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "rabbitmq" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id                   = var.public_subnet_id
  associate_public_ip_address = true

  vpc_security_group_ids = [aws_security_group.rabbitmq.id]
  iam_instance_profile   = aws_iam_instance_profile.rabbitmq.name

  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -e

    yum update -y
    yum install -y docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user

    docker run -d \
      --hostname rabbitmq \
      --name rabbitmq \
      --restart=always \
      -p 5672:5672 \
      -p 15672:15672 \
      -p 15692:15692 \
      -e RABBITMQ_DEFAULT_USER=admin \
      -e RABBITMQ_DEFAULT_PASS=${var.rabbitmq_password} \
      rabbitmq:3.12-management

    sleep 30

    # Enable Prometheus plugin
    docker exec rabbitmq rabbitmq-plugins enable rabbitmq_prometheus

    # Setup exchanges and queues for DLQ + retry pattern
    docker exec rabbitmq rabbitmqadmin declare exchange \
      name=orders.dlx type=direct durable=true

    docker exec rabbitmq rabbitmqadmin declare queue \
      name=orders.dlq durable=true

    docker exec rabbitmq rabbitmqadmin declare queue \
      name=orders durable=true \
      arguments='{"x-dead-letter-exchange":"orders.dlx","x-dead-letter-routing-key":"orders.dlq"}'

    docker exec rabbitmq rabbitmqadmin declare queue \
      name=orders.retry.5s durable=true \
      arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"orders","x-message-ttl":5000}'

    docker exec rabbitmq rabbitmqadmin declare queue \
      name=orders.retry.30s durable=true \
      arguments='{"x-dead-letter-exchange":"","x-dead-letter-routing-key":"orders","x-message-ttl":30000}'

    docker exec rabbitmq rabbitmqadmin declare queue \
      name=orders.parking-lot durable=true

    docker exec rabbitmq rabbitmqadmin declare binding \
      source=orders.dlx destination=orders.dlq routing_key=orders.dlq

    echo "RabbitMQ setup completed successfully"
  USERDATA
  )

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-rabbitmq"
    Environment = var.environment
  }
}