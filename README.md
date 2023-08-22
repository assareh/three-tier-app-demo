# three tier app demo

This repository deploys a simple three-tiered web application into AWS.

## high level steps

### docker
    a. create a container repository
    b. publish docker image to the registry

### terraform
    a. set tfvars
    b. terraform apply
    c. configure kubectl

### kubernetes
    a. apply yaml

## how to deploy
- to deploy the stack, use: [`build.sh`](./build.sh) or use github actions workflows
- to destroy the stack, use [`cleanup.sh`](./cleanup.sh)

### how to verify data in database:
```
docker exec -it CID mongo
use admin
db.auth("username", "password");
show dbs
use go-mongodb
show collections
db.todos.find()
db.user.find()
```
