#!/bin/bash

echo "Kubernetes..."
cd k8s
kubectl delete -f tasky-deployment.yaml

echo "Terraform..."
cd ../terraform
terraform destroy -auto-approve -var my_ip=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)/32

echo "Docker..."
cd ../docker
aws ecr batch-delete-image --repository-name tasky \
    --image-ids "$(aws ecr list-images --repository-name tasky --query 'imageIds[*]' --output json)" || true
terraform destroy -auto-approve