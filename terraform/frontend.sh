#!/bin/bash
component=$1 #passing the ENV from $1 to $2
environment=$2
app_version=$3
dnf install ansible -y    #to connect AWS we need to install both this libraries
pip3.9 install botocore boto3
ansible-pull -i localhost, -U https://github.com/This-is-ravi/expense-ansible-roles.git main.yaml -e component=$component -e env=$environment -e appVersion=$3