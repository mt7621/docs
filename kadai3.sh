#!/bin/bash

sudo yum install -y jq curl docker git mariadb105 --allowerasing
sudo usermod -aG docker ec2-user
sudo systemctl enable docker
sudo systemctl restart docker

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

ARCH=amd64
PLATFORM=$(uname -s)_$ARCH
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"
tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz
sudo mv /tmp/eksctl /usr/local/bin

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash



curl -LO https://github.com/derailed/k9s/releases/latest/download/k9s_linux_amd64.rpm
sudo rpm -i k9s_linux_amd64.rpm

sudo dnf install -y https://dl.k6.io/rpm/repo.rpm
sudo dnf install -y k6


TEMPOUT=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.0.0/website/content/en/docs/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-wsi-eks-cluster" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=wsi-eks-cluster"


kubectl apply -f ~/eks/ns.yaml
