provider "aws" {
  region = var.region

  assume_role {
    role_arn     = var.aws_role_arn
    session_name = var.TFC_RUN_ID
  }
}

resource "random_pet" "suffix" {}

locals {
  project_name         = random_pet.suffix.id
  private_key_filename = "${var.private_key_path}${local.project_name}-ssh-key.pem"
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.1"

  name = local.project_name

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"] # EKS seems to require at least two AZs
  public_subnets  = ["10.0.3.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.project_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.project_name
  cluster_version = "1.27"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = [var.instance_type]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }
}

# S3 --------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket = "${local.project_name}-backups"
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "allow_public_download" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.allow_public_download.json
}

data "aws_iam_policy_document" "allow_public_download" {
  statement {
    sid = "PublicRead"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_website_configuration" "index" {
  bucket = aws_s3_bucket.backups.id
  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_cors_configuration" "this" {
  bucket = aws_s3_bucket.backups.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["http://${aws_s3_bucket.backups.id}.s3-website-${aws_s3_bucket.backups.region}.amazonaws.com"]
    expose_headers  = ["x-amz-server-side-encryption", "x-amz-request-id", "x-amz-id-2"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_object" "index_html" {
  bucket         = aws_s3_bucket.backups.id
  key            = "index.html"
  content_base64 = data.http.index_html.response_body_base64
  content_type   = "text/html"
}

data "http" "index_html" {
  url = "https://raw.githubusercontent.com/qoomon/aws-s3-bucket-browser/master/index.html"
}

# EC2 --------------------------------------------------
resource "aws_security_group" "db" {
  name = "${local.project_name}-db"

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/22"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    prefix_list_ids = []
  }
}

resource "tls_private_key" "this" {
  algorithm = "RSA"
}

resource "aws_key_pair" "this" {
  key_name   = "${local.project_name}-ssh-key.pem"
  public_key = tls_private_key.this.public_key_openssh
}

resource "local_sensitive_file" "pem_file" {
  filename             = pathexpand(local.private_key_filename)
  file_permission      = "600"
  directory_permission = "700"
  content              = tls_private_key.this.private_key_pem
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "db" {
  ami                         = data.aws_ami.ubuntu.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.db.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.this.key_name
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.db.id]

  tags = {
    Name = "mongo"
  }

  user_data = <<EOF
#!/bin/bash

# Capture and redirect
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>/root/setup.log 2>&1

# Everything below will go to the file 'setup.log':

# print executed commands
set -x

# set up mongodb
sudo apt-get update
sudo apt-get install -y docker.io awscli python
sudo docker run \
  -d -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=${var.mongodb_username} \
  -e MONGO_INITDB_ROOT_PASSWORD=${var.mongodb_password} \
  mongo:4.4.23

# partition and mount backups volume
mkfs -t xfs /dev/nvme1n1
mkdir /mnt/backups
mount -t auto -v /dev/nvme1n1 /mnt/backups

# enable cloudwatch logging
echo Creating cloudwatch config file in /root/awslogs.conf
cat <<EOC >/root/awslogs.conf
[general]
state_file = /var/awslogs/state/agent-state
[/root/backup.log]
datetime_format = %b %d %H:%M:%S
file = /root/backup.log
buffer_duration = 5000
log_stream_name = {hostname}
initial_position = start_of_file
log_group_name = /root/backup.log
EOC

echo Downloading cloudwatch logs setup agent
wget https://s3.amazonaws.com/aws-cloudwatch/downloads/latest/awslogs-agent-setup.py
echo running non-interactive cloudwatch-logs setup script
python ./awslogs-agent-setup.py --region ${var.region} --non-interactive --configfile=/root/awslogs.conf

service awslogs start

# write the backup script
cat > /root/backup.sh <<END
#!/bin/bash

BUCKET_NAME=${aws_s3_bucket.backups.id}
FILE_NAME=instance-backup

# append timestamp
TS_FILE_NAME=\$FILE_NAME-\$(date "+%Y.%m.%d-%H.%M.%S").img.gz

# create a backup image
echo "Beginning drive cloning to /mnt/backups/\$TS_FILE_NAME..."
dd if=/dev/nvme0n1p1 conv=sync,noerror bs=128K status=progress | gzip -c > /mnt/backups/\$TS_FILE_NAME
echo "Finished drive cloning to /mnt/backups/\$TS_FILE_NAME!"

# upload to s3
echo "Beginning s3 upload of \$TS_FILE_NAME..."
aws s3 cp /mnt/backups/\$TS_FILE_NAME s3://\$BUCKET_NAME
echo "Finished s3 upload of \$TS_FILE_NAME!"

# clean up local backup
echo "Removing local backup file /mnt/backups/\$TS_FILE_NAME..."
rm -rf /mnt/backups/\$TS_FILE_NAME
echo "Backup complete!"
END

chmod +x /root/backup.sh

# set up cron
crontab<<EOC
@hourly /root/backup.sh > /root/backup.log
EOC

echo "Setup is complete!"
EOF
  # improvements could include error handling, etc
}

data "aws_instance" "db" {
  instance_id = aws_instance.db.id
}

resource "aws_ebs_volume" "backup" {
  availability_zone = data.aws_instance.db.availability_zone
  size              = 8
}

resource "aws_volume_attachment" "backup" {
  device_name = "/dev/sdx"
  volume_id   = aws_ebs_volume.backup.id
  instance_id = aws_instance.db.id
}

resource "aws_iam_instance_profile" "db" {
  name = local.project_name
  role = aws_iam_role.db.name
}

resource "aws_iam_role" "db" {
  name               = local.project_name
  assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json
}

resource "aws_iam_role_policy" "db" {
  name   = "${local.project_name}-db"
  role   = aws_iam_role.db.id
  policy = data.aws_iam_policy_document.db.json
}

data "aws_iam_policy_document" "assume_role_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "db" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }
}

# CONFIG --------------------------------------------------
resource "aws_s3_bucket" "config" {
  bucket = "${local.project_name}-config"
}

resource "aws_config_delivery_channel" "this" {
  name           = local.project_name
  s3_bucket_name = aws_s3_bucket.config.bucket
}

resource "aws_config_configuration_recorder" "this" {
  name     = local.project_name
  role_arn = aws_iam_role.config.arn
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}



data "aws_iam_policy_document" "assume_role_config" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${local.project_name}-config"
  assume_role_policy = data.aws_iam_policy_document.assume_role_config.json
}

data "aws_iam_policy_document" "config" {
  statement {
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.config.arn,
      "${aws_s3_bucket.config.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "config" {
  name   = "${local.project_name}-config"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config.json
}

resource "aws_config_configuration_aggregator" "account" {
  name = local.project_name

  account_aggregation_source {
    account_ids = [data.aws_caller_identity.current.account_id]
    regions     = [var.region]
  }
}

resource "aws_config_aggregate_authorization" "account" {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.region
}

resource "aws_config_conformance_pack" "sec_eks" {
  name          = "Security-Best-Practices-for-EKS"
  template_body = data.http.sec_eks.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "sec_eks" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Security-Best-Practices-for-EKS.yaml"
}

resource "aws_config_conformance_pack" "sec_ecr" {
  name          = "Security-Best-Practices-for-ECR"
  template_body = data.http.sec_ecr.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "sec_ecr" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Security-Best-Practices-for-ECR.yaml"
}

resource "aws_config_conformance_pack" "ops_devops" {
  name          = "Operational-Best-Practices-for-DevOps"
  template_body = data.http.ops_devops.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "ops_devops" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-DevOps.yaml"
}

resource "aws_config_conformance_pack" "ops_ec2" {
  name          = "Operational-Best-Practices-for-EC2"
  template_body = data.http.ops_ec2.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "ops_ec2" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-EC2.yaml"
}

resource "aws_config_conformance_pack" "ops_s3" {
  name          = "Operational-Best-Practices-for-S3"
  template_body = data.http.ops_s3.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "ops_s3" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-Amazon-S3.yaml"
}

resource "aws_config_conformance_pack" "ops_cis_14_l1" {
  name          = "Operational-Best-Practices-for-CIS-AWS-Foundations-Benchmark-Level-1"
  template_body = data.http.ops_cis_14_l1.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "ops_cis_14_l1" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-CIS-AWS-v1.4-Level1.yaml"
}

resource "aws_config_conformance_pack" "ops_cis_14_l2" {
  name          = "Operational-Best-Practices-for-CIS-AWS-Foundations-Benchmark-Level-2"
  template_body = data.http.ops_cis_14_l2.response_body

  depends_on = [aws_config_configuration_recorder.this]
}

data "http" "ops_cis_14_l2" {
  url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-CIS-AWS-v1.4-Level2.yaml"
}
