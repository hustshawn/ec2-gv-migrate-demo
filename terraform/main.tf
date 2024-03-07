provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  name     = "gv-demo"
  region   = "ap-east-1"
  vpc_cidr = "10.18.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  # You can update the user data based on your existing bootstrap image.
  user_data = <<-EOT
    #!/bin/bash
    echo "Hello Terraform!";
    sudo apt-get update -y;
    sudo apt install -y php php-cli php-fpm php-json php-common php-mysql php-zip php-gd php-mbstring php-curl php-xml php-pear php-bcmath;
    sudo systemctl disable --now apache2;
    sudo apt install -y nginx php7.4-fpm;
    cd /tmp && curl -sS https://getcomposer.org/installer | php;
    sudo mv composer.phar /usr/local/bin/composer;
    cd /home/ubuntu/basic && docker compose up -d;
  EOT

  # Prepare your Graviton instance golden image before you run this script. 
  gv_ami_id        = "ami-0123456789012345"
  gv_instance_type = "c6g.large"
  # Your AMD64 instance golden image id
  amd64_ami_id        = "ami-amd6401234567890"
  amd64_instance_type = "c6i.large"
  tags = {
    Blueprint = local.name
  }
}

# Can use this data source to get the latest arm64 Ubuntu AMI
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-arm64-server-*",
    ]
  }
}
# Can use this data source to get the latest amd64 Ubuntu AMI
data "aws_ami" "ubuntu_amd64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*",
    ]
  }
}


resource "aws_iam_instance_profile" "ssm" {
  name = "${local.name}_profile"
  role = aws_iam_role.ssm.name
  tags = local.tags
}

resource "aws_iam_role" "ssm" {
  name = local.name
  tags = local.tags

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

module "asg_graviton" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "7.4.0"

  # Autoscaling group
  name = "${local.name}-gv-asg"

  vpc_zone_identifier = module.vpc.private_subnets
  min_size            = 0
  max_size            = 1
  desired_capacity    = 1

  # Traffic source attachment
  create_traffic_source_attachment = true
  traffic_source_type              = "elbv2"
  traffic_source_identifier        = module.alb.target_group_arns[1]

  image_id           = local.gv_ami_id
  instance_type      = local.gv_instance_type
  capacity_rebalance = true

  iam_instance_profile_arn = aws_iam_instance_profile.ssm.arn

  user_data = base64encode(local.user_data)

  security_groups = [module.asg_sg.security_group_id]

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      checkpoint_delay       = 600
      checkpoint_percentages = [35, 70, 100]
      instance_warmup        = 300
      min_healthy_percentage = 50
      max_healthy_percentage = 100
      skip_matching          = true
    }
    triggers = ["tag"]
  }

  tags = local.tags
}


module "asg_amd64" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "7.4.0"

  # Autoscaling group
  name = "${local.name}-amd64-asg"

  vpc_zone_identifier = module.vpc.private_subnets
  min_size            = 0
  max_size            = 1
  desired_capacity    = 1

  # Traffic source attachment
  create_traffic_source_attachment = true
  traffic_source_type              = "elbv2"
  traffic_source_identifier        = module.alb.target_group_arns[0]

  image_id           = local.amd64_ami_id
  instance_type      = local.amd64_instance_type
  capacity_rebalance = true

  iam_instance_profile_arn = aws_iam_instance_profile.ssm.arn

  user_data = base64encode(local.user_data)

  security_groups = [module.asg_sg.security_group_id]

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      checkpoint_delay       = 600
      checkpoint_percentages = [35, 70, 100]
      instance_warmup        = 300
      min_healthy_percentage = 50
      max_healthy_percentage = 100
      skip_matching          = true
    }
    triggers = ["tag"]
  }

  tags = local.tags
}


################################################################################
# Supporting Resources
################################################################################
module "asg_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "A security group for gv-demo instances"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [module.vpc.vpc_cidr_block]

  ingress_with_cidr_blocks = [
    # debugging only, can delete later
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "http service port"
      cidr_blocks = "0.0.0.0/0"
    },
    # can just keep port 8000 only.
    {
      from_port   = 8000
      to_port     = 8090
      protocol    = "tcp"
      description = "User-service ports"
      cidr_blocks = "0.0.0.0/0"
    },
    # debugging only, can delete later
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "ssh"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}
