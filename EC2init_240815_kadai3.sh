sed -i 's/#Port\s22/Port 4272/' /etc/ssh/sshd_config
# sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
# echo 'Skills2024**' | passwd --stdin ec2-user
systemctl restart sshd

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


#3rd

AWSuserID=$(aws sts get-caller-identity --query "Account" --output text)
AWSprvA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-app-a --query "Subnets[0].SubnetId" --output text)
AWSprvB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-app-b --query "Subnets[0].SubnetId" --output text)
AWSpubA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-public-a --query "Subnets[0].SubnetId" --output text)
AWSpubB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-public-b --query "Subnets[0].SubnetId" --output text)
AWSalbsgID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsi-app-alb-sg" --query "SecurityGroups[*].GroupId" --output text)
AWSrdsEndPoint=$(aws rds describe-db-instances --query "DBInstances[*].Endpoint.Address" --output text)


sed -i -e "s/subnet-0bc715b9079b75cfe/$AWSprvA/" ./cluster.yaml
sed -i -e "s/subnet-0adb0828c3ec1e4cc/$AWSprvB/" ./cluster.yaml
sed -i -e "s/702661606257/$AWSuserID/" ./cluster.yaml


cd eks
eksctl create cluster -f cluster.yaml

kubectl apply -f ns.yaml	


curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
	
eksctl create iamserviceaccount \
  --cluster=wsi-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$AWSuserID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region ap-northeast-2
  
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wsi-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller 




CLUSTER_NAME=wsi-eks-cluster
AWS_PARTITION="aws"
AWS_REGION="$(aws configure list | grep region | tr -s " " | cut -d" " -f3)"
OIDC_ENDPOINT="$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.identity.oidc.issuer" --output text)"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

echo '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}' > node-trust-policy.json

aws iam create-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --assume-role-policy-document file://node-trust-policy.json
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name "KarpenterNodeRole-${CLUSTER_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
aws iam add-role-to-instance-profile --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" --role-name "KarpenterNodeRole-${CLUSTER_NAME}"

cat << EOF > controller-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT#*//}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_ENDPOINT#*//}:aud": "sts.amazonaws.com",
                    "${OIDC_ENDPOINT#*//}:sub": "system:serviceaccount:karpenter:karpenter"
                }
            }
        }
    ]
}
EOF

aws iam create-role --role-name KarpenterControllerRole-${CLUSTER_NAME} --assume-role-policy-document file://controller-trust-policy.json

cat << EOF > controller-policy.json
{
    "Statement": [
        {
            "Action": [
                "ssm:GetParameter",
                "ec2:DescribeImages",
                "ec2:RunInstances",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeLaunchTemplates",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:DescribeAvailabilityZones",
                "ec2:DeleteLaunchTemplate",
                "ec2:CreateTags",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateFleet",
                "ec2:DescribeSpotPriceHistory",
                "pricing:GetProducts"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "Karpenter"
        },
        {
            "Action": "ec2:TerminateInstances",
            "Condition": {
                "StringLike": {
                    "ec2:ResourceTag/Name": "*karpenter*"
                }
            },
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "ConditionalEC2Termination"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}",
            "Sid": "PassNodeIAMRole"
        },
        {
            "Effect": "Allow",
            "Action": "eks:DescribeCluster",
            "Resource": "arn:${AWS_PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}",
            "Sid": "EKSClusterEndpointLookup"
        }
    ],
    "Version": "2012-10-17"
}
EOF

aws iam put-role-policy --role-name KarpenterControllerRole-${CLUSTER_NAME} --policy-name KarpenterControllerPolicy-${CLUSTER_NAME} --policy-document file://controller-policy.json


aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources $(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name wsi-app-ng --query 'nodegroup.subnets' --output text )


LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name wsi-app-ng --query 'nodegroup.launchTemplate.{id:id,version:version}' --output text | tr -s "\t" ",")

SECURITY_GROUPS=$(aws ec2 describe-launch-template-versions --launch-template-id ${LAUNCH_TEMPLATE%,*} --versions ${LAUNCH_TEMPLATE#*,} --query 'LaunchTemplateVersions[0].LaunchTemplateData.[NetworkInterfaces[0].Groups||SecurityGroupIds]' --output text)

aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources ${SECURITY_GROUPS}

kubectl edit configmap aws-auth -n kube-system

# apiVersion: v1
# data:
#   mapRoles: |
#     - groups:
#       - system:bootstrappers
#       - system:nodes
#       rolearn: arn:aws:iam::111122223333:role/dev-global-eks-node-iam-role
#       username: system:node:{{EC2PrivateDNSName}}
# +   - groups:
# +     - system:bootstrappers
# +     - system:nodes
# +     rolearn: arn:aws:iam::111122223333:role/KarpenterNodeRole-YOUR_CLUSTER_NAME_HERE
# +     username: system:node:{{EC2PrivateDNSName}}
# kind: ConfigMap
# metadata:
#   ...


helm template karpenter oci://public.ecr.aws/karpenter/karpenter \
    --namespace karpenter \
    --set settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
    --set settings.aws.clusterName=${CLUSTER_NAME} \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set controller.resources.requests.cpu=1 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=1 \
    --set controller.resources.limits.memory=1Gi \
    --set replicas=2 > karpenter.yaml

vi karpenter.yaml

kubectl create namespace karpenter

kubectl api-resources --categories karpenter -o wide

kubectl apply -f karpenter.yaml

kubectl get pod -n karpenter

$ cat <<EOF | kubectl apply -f -
---
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
	  taints:
	    - key: "wsi"
		  value: "app"
		  effect: NoSchedule
      requirements:
      - key: "karpenter.k8s.aws/instance-category"
        operator: In
        values: ["t"]
      - key: "karpenter.k8s.aws/instance-cpu"
        operator: Gt
        values: ["2"]
      - key: "karpenter.k8s.aws/instance-generation"
        operator: Gt
        values: ["3"]
	  - key: "karpenter.k8s.aws/instance-family"
        operator: In
        values: ["t3"]
      - key: "karpenter.k8s.aws/instance-size"
        operator: In
        values: ["micro"]
      - key: "topology.kubernetes.io/zone"
        operator: In
        values: ["ap-northeast-2a", "ap-northeast-2b"]
      - key: "kubernetes.io/arch"
        operator: In
        values: ["amd64"]
      - key: "karpenter.sh/capacity-type"
        operator: In
        values: ["on-demand"]
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: "${CLUSTER_NAME}"

  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: "${CLUSTER_NAME}"
EOF








kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl autoscale deployment token-deploy --cpu-percent=50 --min=2 --max=10 -n wsi
kubectl autoscale deployment employee-deploy --cpu-percent=50 --min=2 --max=10 -n wsi

















eksctl create iamserviceaccount --name secretmanager --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/secrets_manager_full_access --region ap-northeast-2 --approve
eksctl create iamserviceaccount --name dynamodb --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/dynamodb-kms-policy --region ap-northeast-2 --approve


eksctl create iamserviceaccount --name dynamodbaccess --namespace wsc2024 --cluster wsc2024-eks-cluster --attach-policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess --region us-east-1 --approve


cd ../employee
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
sed -i -e "s/wsc2024-db-cluster.cluster-cvuu26s24sdo.us-east-1.rds.amazonaws.com/$AWSrdsEndPoint/" ./deployment.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

cd ../token
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

  


cd ../employee
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ../token
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ~/eks
sed -i -e "s/subnet-0478cba2abda57345/$AWSpubA/" ./ingress.yaml
sed -i -e "s/subnet-004b490933a200da3/$AWSpubB/" ./ingress.yaml
sed -i -e "s/sg-0439f7bb7abb9d0c7/$AWSalbsgID/" ./ingress.yaml


kubectl apply -f ingress.yaml




aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 690677342176.dkr.ecr.us-east-1.amazonaws.com

docker tag customer-repo:latest 690677342176.dkr.ecr.us-east-1.amazonaws.com/customer-repo:latest
docker tag product-repo:latest 690677342176.dkr.ecr.us-east-1.amazonaws.com/product-repo:latest
docker tag order-repo:latest 690677342176.dkr.ecr.us-east-1.amazonaws.com/order-repo:latest

docker push 690677342176.dkr.ecr.us-east-1.amazonaws.com/customer-repo:latest
docker push 690677342176.dkr.ecr.us-east-1.amazonaws.com/product-repo:latest
docker push 690677342176.dkr.ecr.us-east-1.amazonaws.com/order-repo:latest
