module "frontend" { #instance creation
  source  = "terraform-aws-modules/ec2-instance/aws"
  #key_name = aws_key_pair.vpn.key_name , here we dont need key,we r using our own AMI
  name = "${var.project_name}-${var.environment}-${var.common_tags.Component}" #expense-dev-frontend

  instance_type          = "t3.micro"
  vpc_security_group_ids = [data.aws_ssm_parameter.frontend_sg_id.value]
  # convert StringList to list and get first element
  subnet_id = local.public_subnet_id
  ami = data.aws_ami.ami_info.id
  
  tags = merge(
    var.common_tags,
    {
        Name = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
    }
  )
}


resource "null_resource" "frontend" {
    triggers = {
      instance_id = module.frontend.id # this will be triggered everytime instance is created
    }

    connection { # after running the server we need to establish the connection
        type     = "ssh"
        user     = "ec2-user"
        password = "DevOps321"
        host     = module.frontend.private_ip # we r connecting with vpn,no need public ip
    }
     
     # here to get connection with frontend u need to connect to the vpn 

    provisioner "file" { # this file wil copy from local to server
        source      = "${var.common_tags.Component}.sh"
        destination = "/tmp/${var.common_tags.Component}.sh"
    }

    provisioner "remote-exec" { #to run that copied file we use remote exec
        inline = [
            "chmod +x /tmp/${var.common_tags.Component}.sh",  # giving execution permissions
            "sudo sh /tmp/${var.common_tags.Component}.sh ${var.common_tags.Component} ${var.environment} ${var.app_version}"
        ]
    } 
}

#stop the server
resource "aws_ec2_instance_state" "frontend" {
  instance_id = module.frontend.id
  state       = "stopped"
  # stop the serever only when null resource provisioning is completed
  depends_on = [ null_resource.frontend ]
}

# take AMI from instance
resource "aws_ami_from_instance" "frontend" {
  name               = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
  source_instance_id = module.frontend.id
  depends_on = [ aws_ec2_instance_state.frontend ] #take when instance is stop
}


resource "null_resource" "frontend_delete" {
    triggers = {
      instance_id = module.frontend.id # this will be triggered everytime instance is created
    }

    
 
    provisioner "local-exec" {
        command = "aws ec2 terminate-instances --instance-ids ${module.frontend.id}" #AWS ec2 terminate AWS CLI
        #interpreter = ["/bin/bash", "-c"]
    } 

    depends_on = [ aws_ami_from_instance.frontend ]
}

#after terminating the instance now create the target group

resource "aws_lb_target_group" "frontend" {
  name     = "${var.project_name}-${var.environment}-${var.common_tags.Component}" #expense-dev-frontend
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_ssm_parameter.vpc_id.value
  health_check {
    path                = "/"
    port                = 80
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-299"
  }
}

# launch template its like job description

resource "aws_launch_template" "frontend" {
  name = "${var.project_name}-${var.environment}-${var.common_tags.Component}"

  image_id = aws_ami_from_instance.frontend.id
  instance_initiated_shutdown_behavior = "terminate"
  instance_type = "t3.micro"
  update_default_version = true # if any updates(eg:AMI changes) then its sets the latest version to default

  vpc_security_group_ids = [data.aws_ssm_parameter.frontend_sg_id.value]

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.common_tags,
      {
        Name = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
      }
    )
  }
}

# autoscaling group = HR

resource "aws_autoscaling_group" "frontend" {
  name                      = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
  max_size                  = 5
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 1 
  target_group_arns = [aws_lb_target_group.frontend.arn] # now ASG wil place that instance in this target grp
  launch_template {  #if update in the launch template ,here it wil take latest version
    id      = aws_launch_template.frontend.id
    version = "$Latest"  
  }

  vpc_zone_identifier       = split(",", data.aws_ssm_parameter.public_subnet_ids.value) #in which subnet we need to launch
  # split - function is used to convert the comma-separated string of subnet IDs into a list.
  #eg : "subnet-abc123,subnet-def456,subnet-ghi789"

  instance_refresh { #once launch template is updated , we need to do instace refresh
    strategy = "Rolling" #creating new and deleting old version
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"] #its should trigger when launch template is updated
  }

  tag {  #while Auto scaling it wil create instances for that we giving names
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }

  tag {
    key                 = "Project"
    value               = "${var.project_name}"
    propagate_at_launch = false
  }
}

#now create auto scaling policy

resource "aws_autoscaling_policy" "frontend" {
  name                   = "${var.project_name}-${var.environment}-${var.common_tags.Component}"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.frontend.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 10.0
  }
}

#now add rule to the listener

resource "aws_lb_listener_rule" "frontend" {
  listener_arn = data.aws_ssm_parameter.web_alb_listener_arn_https.value
  priority     = 100 # less number will be first validated

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {  #if anyone requests "frontend.app-dev.csvdaws78s.online" then req wil goto frontend
    host_header {
      values = ["web-${var.environment}.${var.zone_name}"] #if user hits web-dev.csvdaws78s.online it goes to FE
    }
  }
}


