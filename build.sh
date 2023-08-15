#!/bin/bash

echo "Docker..."
cd docker
terraform apply -auto-approve
docker build -t tasky .
DOCKER_TAG=$(terraform output -raw container_registry_url)
docker tag tasky:latest $DOCKER_TAG
docker push $DOCKER_TAG

echo "Terraform..."
cd ../terraform
terraform apply -auto-approve -var my_ip=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)/32
MONGO_IP=$(terraform output -raw db_instance_private_ip)
MONGO_USERNAME=$(terraform output -raw mongodb_username)
MONGO_PASSWORD=$(terraform output -raw mongodb_password)
aws eks --region $(terraform output -raw region) update-kubeconfig \
    --name $(terraform output -raw cluster_name)

echo "Kubernetes..."
cd ../k8s
cat > tasky-deployment.yaml <<EOF           
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tasky-deployment
  labels:
    app: tasky
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
kind: ServiceAccount
metadata:
  name: tasky
EOF
kubectl apply -f tasky-deployment.yaml
kubectl create clusterrolebinding admin \
  --clusterrole=cluster-admin \
  --serviceaccount=default:tasky

# want to wait until the load balancer public dns is available
lb_address=""
while [ -z $lb_address ]; do
  echo "Waiting for load balancer..."
  lb_address=$(kubectl get svc tasky-service-loadbalancer --template="{{range .status.loadBalancer.ingress}}{{.hostname}}{{end}}")
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
