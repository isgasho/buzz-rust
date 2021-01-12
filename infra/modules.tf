##### HBEE #####

resource "aws_iam_policy" "s3-additional-policy" {
  name        = "${module.env.module_name}_s3_access_${module.env.region_name}_${module.env.stage}"
  description = "additional policy for s3 access"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Resource": "*",
      "Effect": "Allow"
    }
  ]
}
EOF
}

module "hbee" {
  source = "./lambda"

  function_base_name = "hbee"
  filename           = "../code/target/docker/hbee_lambda.zip"
  handler            = "N/A"
  memory_size        = 2048
  timeout            = 10
  runtime            = "provided"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  additional_policies = [aws_iam_policy.s3-additional-policy.arn]
  environment = {
    GIT_REVISION = var.git_revision
  }
}

##### HCOMB #####

resource "aws_ecr_repository" "hcomb_repo" {
  name                 = "${module.env.module_name}-hcomb-${module.env.stage}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "null_resource" "hcomb_push" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
      docker tag "cloudfuse/buzz-rust-hcomb:${var.git_revision}" "${aws_ecr_repository.hcomb_repo.repository_url}:${var.git_revision}"
      docker push "${aws_ecr_repository.hcomb_repo.repository_url}:${var.git_revision}"
    EOT
  }
}

module "hcomb" {
  source = "./fargate"

  name                        = "hcomb"
  vpc_id                      = module.vpc.vpc_id
  task_cpu                    = 2048
  task_memory                 = 4096
  ecs_cluster_id              = aws_ecs_cluster.hcomb_cluster.id
  ecs_cluster_name            = aws_ecs_cluster.hcomb_cluster.name
  ecs_task_execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  docker_image                = "${aws_ecr_repository.hcomb_repo.repository_url}:${var.git_revision}"
  subnets                     = module.vpc.public_subnets
  local_ip                    = "${chomp(data.http.icanhazip.body)}/32"

  environment = [{
    name  = "GIT_REVISION"
    value = var.git_revision
    }, {
    name  = "AWS_REGION"
    value = module.env.region_name
  }]
}

##### FUSE #####

resource "aws_iam_policy" "fargate-additional-policy" {
  name        = "${module.env.module_name}_fargate_access_${module.env.region_name}_${module.env.stage}"
  description = "additional policy for fargate access"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ecs:RunTask",
        "ecs:StartTask",
        "ecs:DescribeTasks",
        "ecs:ListTasks"
      ],
      "Resource": "*",
      "Effect": "Allow"
    },
    {
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "${aws_iam_role.ecs_task_execution_role.arn}",
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "lambda-additional-policy" {
  name        = "${module.env.module_name}_lambda_access_${module.env.region_name}_${module.env.stage}"
  description = "additional policy for lambda access"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Resource": "*",
      "Effect": "Allow"
    }
  ]
}
EOF
}

module "fuse" {
  source = "./lambda"

  function_base_name = "fuse"
  filename           = "../code/target/docker/fuse_lambda.zip"
  handler            = "N/A"
  memory_size        = 2048
  timeout            = 30
  runtime            = "provided"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  additional_policies = [aws_iam_policy.fargate-additional-policy.arn, aws_iam_policy.lambda-additional-policy.arn]
  environment = {
    GIT_REVISION       = var.git_revision
    HBEE_LAMBDA_NAME   = module.hbee.lambda_name
    HCOMB_CLUSTER_NAME = aws_ecs_cluster.hcomb_cluster.name
    HCOMB_TASK_SG_ID   = module.hcomb.task_security_group_id
    HCOMB_TASK_DEF_ARN = module.hcomb.task_definition_arn
    PUBLIC_SUBNETS     = join(",", module.vpc.public_subnets)
  }
}