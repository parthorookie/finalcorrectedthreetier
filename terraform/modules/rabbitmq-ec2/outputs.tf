output "private_ip" {
  value = aws_instance.rabbitmq.private_ip
}

output "instance_id" {
  value = aws_instance.rabbitmq.id
}
