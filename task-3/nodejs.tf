provider "aws" {
  region = "ap-south-1"
}

provider "tls" {}

# VPC resource
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "NODEJS-VPC"
  }
}

# Subnet resource
resource "aws_subnet" "my_subnet" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-south-1a"
  tags = {
    Name = "NODEJS-Subnet"
  }
}

# Internet Gateway resource
resource "aws_internet_gateway" "my_internet_gateway" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "NODEJS-IGW"
  }
}

# Route Table resource
resource "aws_route_table" "my_route_table" {
  vpc_id = aws_vpc.my_vpc.id

  # Add route to route traffic to the Internet Gateway
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my_internet_gateway.id
  }

  tags = {
    Name = "NODEJS-RouteTable"
  }
}

# Associate the route table with the subnet
resource "aws_route_table_association" "my_route_table_association" {
  subnet_id      = aws_subnet.my_subnet.id
  route_table_id = aws_route_table.my_route_table.id
}

# Security group resource
resource "aws_security_group" "my_security_group" {
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH inbound traffic"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP inbound traffic"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "NODEJS-SecurityGroup"
  }
}

# TLS Private Key resource to create a new PEM key
resource "tls_private_key" "my_private_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# AWS Key Pair resource using the generated private key
resource "aws_key_pair" "my_key_pair" {
  key_name   = "my-ec2-key-${timestamp()}"
  public_key = tls_private_key.my_private_key.public_key_openssh
}

# EC2 instance resource
resource "aws_instance" "my_ec2_instance" {
  ami           = "ami-0fd05997b4dff7aac"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.my_subnet.id

  # Assign security group and key pair to the EC2 instance
  vpc_security_group_ids = [aws_security_group.my_security_group.id]
  key_name               = aws_key_pair.my_key_pair.key_name

  # Public IP allocation
  associate_public_ip_address = true

  # Tags for the instance
  tags = {
    Name = "NODEJS-EC2Instance"
  }

  # User data script for setting up NGINX on the instance
  user_data = <<-EOF
                #!/bin/bash
                yum update -y
                amazon-linux-extras enable nginx1
                yum install -y nginx
                systemctl start nginx
                systemctl enable nginx
                systemctl start sshd
                systemctl enable sshd
              EOF
}

# Output the instance's public IP address
output "instance_public_ip" {
  value = aws_instance.my_ec2_instance.public_ip
}

# Output the private key (for downloading)
resource "local_file" "private_key" {
  content  = tls_private_key.my_private_key.private_key_pem
  filename = "${path.module}/my-ec2-key.pem"
}

output "private_key_path" {
  value = local_file.private_key.filename
}

# Null resource to run Ansible playbook
resource "null_resource" "ansible_deploy" {
  depends_on = [aws_instance.my_ec2_instance]

  triggers = {
    instance_state = aws_instance.my_ec2_instance.id
  }

  provisioner "local-exec" {
    command = <<EOT
      chmod 400 ./my-ec2-key.pem
      echo "[ec2]" > inventory.ini
      echo "${aws_instance.my_ec2_instance.public_ip} ansible_user=ec2-user ansible_ssh_private_key_file=./my-ec2-key.pem ansible_ssh_common_args='-o StrictHostKeyChecking=no'" >> inventory.ini

      echo "Checking if SSH (port 22) is available on the instance..."
      for i in {1..10}; do
        nc -zv ${aws_instance.my_ec2_instance.public_ip} 22 && break
        echo "Port 22 not open yet. Retrying in 5 seconds..."
        sleep 5
      done

      # Run Ansible playbook
      echo "Running Ansible playbook..."
      ansible-playbook -i inventory.ini playbook.yml
    EOT
  }
}
