#!/bin/bash
# usage: ./destroy.sh <AWS provisioning role to assume>
AWS_TERRAFORM_ROLE=$1

if [ $# -lt 1 ]
  then
    echo "Missing required argument, see usage."
  else

# AWS=$(aws sts assume-role --role-arn $AWS_TERRAFORM_ROLE --output json --role-session-name AWSCLI-Session)
# export AWS_ACCESS_KEY_ID=$(echo $AWS | jq -r '.Credentials''.AccessKeyId')
# export AWS_SECRET_ACCESS_KEY=$(echo $AWS | jq -r '.Credentials''.SecretAccessKey')
# export AWS_SESSION_TOKEN=$(echo $AWS | jq -r '.Credentials''.SessionToken')

echo "Kubernetes..."
cd k8s
kubectl delete -f tasky-deployment.yaml

echo "Terraform..."
cd ../terraform
terraform destroy -auto-approve -var-file="myip.tfvars" -var aws_role_arn=$AWS_TERRAFORM_ROLE

echo "Docker..."
cd ../docker/terraform
aws ecr batch-delete-image --repository-name tasky \
    --image-ids "$(aws ecr list-images --repository-name tasky --query 'imageIds[*]' --output json)" || true
terraform destroy -auto-approve -var aws_role_arn=$AWS_TERRAFORM_ROLE

fi