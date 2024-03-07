module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.10"


  name = "gv-demo-tf-alb"

  load_balancer_type = "application"

  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = false


  security_groups = [module.alb_sg.security_group_id]

  http_tcp_listeners = [
    # Forward action is default, either when defined or undefined
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    },
  ]

  http_tcp_listener_rules = [
    {
      https_listener_index = 0
      priority             = 1

      actions = [{
        type = "weighted-forward"
        target_groups = [
          {
            target_group_index = 0
            weight             = 1
          },
          {
            target_group_index = 1
            weight             = 1
          }
        ]
      }]
      conditions = [{
        path_patterns = ["/"]
      }]
    },
  ]
  target_groups = [
    {
      name_prefix          = "amd64"
      backend_protocol     = "HTTP"
      backend_port         = 8000
      target_type          = "instance"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 2
        unhealthy_threshold = 3
        timeout             = 6
        protocol            = "HTTP"
        matcher             = "200-399"
      }
      tags = local.tags
    },
    {
      name_prefix          = "arm64"
      backend_protocol     = "HTTP"
      backend_port         = 8000
      target_type          = "instance"
      deregistration_delay = 10
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 2
        unhealthy_threshold = 3
        timeout             = 6
        protocol            = "HTTP"
        matcher             = "200-399"
      }
      tags = local.tags
    },
  ]

  tags = local.tags
}

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name}-alb-sg"
  description = "A security group for alb"
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
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

output "alb_dns" {
  value = "http://${module.alb.lb_dns_name}"
}

