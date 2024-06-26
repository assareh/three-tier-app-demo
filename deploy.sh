#!/bin/bash
# usage: ./deploy.sh <AWS provisioning role to assume>
AWS_TERRAFORM_ROLE=$1

if [ $# -lt 1 ]
  then
    echo "Missing required argument, see usage."
  else

echo "Docker..."
cd docker/terraform
terraform init && terraform apply -auto-approve -var aws_role_arn=$AWS_TERRAFORM_ROLE
DOCKER_TAG=$(terraform output -raw container_registry_url)
aws ecr get-login-password --region $(terraform output -raw region) | docker login --username AWS --password-stdin $DOCKER_TAG
cd ..
docker build --platform linux/amd64 -t tasky .
docker tag tasky:latest $DOCKER_TAG
docker push $DOCKER_TAG

echo "Terraform Infra..."
cd ../infra
terraform init && terraform apply -auto-approve -var aws_role_arn=$AWS_TERRAFORM_ROLE
MONGO_IP=$(terraform output -raw db_instance_private_ip)
MONGO_USERNAME=$(terraform output -raw mongodb_username)
MONGO_PASSWORD=$(terraform output -raw mongodb_password)
aws eks --region $(terraform output -raw region) update-kubeconfig --name $(terraform output -raw cluster_name)

AWS=$(aws sts assume-role --role-arn $AWS_TERRAFORM_ROLE --output json --role-session-name AWSCLI-Session)
export AWS_ACCESS_KEY_ID=$(echo $AWS | jq -r '.Credentials''.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo $AWS | jq -r '.Credentials''.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo $AWS | jq -r '.Credentials''.SessionToken')

echo "Kubernetes..."
cd ../k8s
cat > tasky-deployment.yaml <<EOF           
apiVersion: v1
kind: Namespace
metadata:
  name: tasky
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tasky
  namespace: tasky
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tasky-deployment
  namespace: tasky
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tasky
  template:
    metadata:
      labels:
        app: tasky
    spec:
      serviceAccountName: tasky
      containers:
      - name: tasky
        image: $DOCKER_TAG
        env:
        - name: MONGODB_URI
          value: mongodb://$MONGO_USERNAME:$MONGO_PASSWORD@$MONGO_IP:27017
        - name: SECRET_KEY
          value: secret123
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: tasky-service-loadbalancer
  namespace: tasky
spec:
  type: LoadBalancer
  selector:
    app: tasky
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
---
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth
type: kubernetes.io/basic-auth
data:
  username: admin
  password: P4ssw0rd
EOF
kubectl apply -f tasky-deployment.yaml

cat > clusterrolebinding.yaml <<EOF           
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tasky
subjects:
  - kind: ServiceAccount
    name: tasky
    namespace: tasky
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
kubectl apply -f clusterrolebinding.yaml

# want to wait until the load balancer public dns is available
lb_address=""
while [ -z $lb_address ]; do
  echo "Waiting for load balancer..."
  lb_address=$(kubectl get svc tasky-service-loadbalancer --namespace tasky --template="{{range .status.loadBalancer.ingress}}{{.hostname}}{{end}}")
  [ -z "$lb_address" ] && sleep 5
done
echo 'Load balancer published but may take a few minutes to become ready:' && echo $lb_address

# want to wait until the service is healthy
echo "Waiting for service health..."
until [ "$(curl -s -w '%{http_code}' -o /dev/null "http://$lb_address")" -eq 200 ]
do
  sleep 5
done

open http://$lb_address/

fi