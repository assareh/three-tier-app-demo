provider "aws" {
  region = var.region
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

  vpc_id                               = module.vpc.vpc_id
  subnet_ids                           = module.vpc.private_subnets
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.my_ips

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
  bucket = local.project_name
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_acl" "public-read" {
  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
  ]

  bucket = aws_s3_bucket.backups.id
  acl    = "public-read"
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
    cidr_blocks = var.my_ips
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
  name   = local.project_name
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
