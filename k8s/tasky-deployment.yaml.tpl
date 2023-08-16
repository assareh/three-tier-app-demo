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
        image: ${docker_tag}
        env:
        - name: MONGODB_URI
          value: mongodb://${mongo_username}:${mongo_password}@${mongo_ip}:27017
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