variable "instance_type" {
  description = "Specifies the AWS instance type"
  default     = "t3.small"
}

variable "mongodb_password" {
  description = "MongoDB root password"
  default     = "password"
}

variable "mongodb_username" {
  description = "MongoDB root username"
  default     = "username"
}

variable "my_ip" {
  description = "My IP address"
}

variable "private_key_path" {
  description = "local path for private key file"
  default     = "~/.ssh/"
}

variable "region" {
  description = "The region where the resources are created"
  default     = "us-west-2"
}
