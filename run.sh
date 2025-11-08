#!/bin/bash
terraform init
terraform fmt   -recursive 
terraform plan  -var-file=envs/dev/terraform.tfvars
terraform apply -var-file=envs/dev/terraform.tfvars