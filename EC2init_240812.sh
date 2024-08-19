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


#CN

AWSuserID=$(aws sts get-caller-identity --query "Account" --output text)
AWSprvA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsc2024-prod-app-sn-a --query "Subnets[0].SubnetId" --output text)
AWSprvB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsc2024-prod-app-sn-b --query "Subnets[0].SubnetId" --output text)
AWSpubA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsc2024-prod-load-sn-a --query "Subnets[0].SubnetId" --output text)
AWSpubB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsc2024-prod-load-sn-b --query "Subnets[0].SubnetId" --output text)
AWSalbsgID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=alb-sg" --query "SecurityGroups[*].GroupId" --output text)
AWSrdsEndPoint=$(aws rds describe-db-clusters --query "DBClusters[*].Endpoint" --output text)


sed -i -e "s/subnet-0bc715b9079b75cfe/$AWSprvA/" ./cluster.yaml
sed -i -e "s/subnet-0adb0828c3ec1e4cc/$AWSprvB/" ./cluster.yaml
sed -i -e "s/702661606257/$AWSuserID/" ./cluster.yaml


cd eks
eksctl create cluster -f cluster.yaml

kubectl apply -f ns.yaml


# login to ECR
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
# Run helm with either install or upgrade
helm install gateway-api-controller \
    oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
    --version=v1.0.6 \
    --set=serviceAccount.create=false \
    --namespace wsc2024 \
    --set=log.level=info # use "debug" for debug level logs
	


curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
eksctl create iamserviceaccount \
  --cluster=wsc2024-eks-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$AWSuserID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region us-east-1
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=wsc2024-eks-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller 


eksctl create iamserviceaccount --name secretmanager --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/secrets_manager_full_access --region ap-northeast-2 --approve
eksctl create iamserviceaccount --name dynamodb --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/dynamodb-kms-policy --region ap-northeast-2 --approve


eksctl create iamserviceaccount --name dynamodbaccess --namespace wsc2024 --cluster wsc2024-eks-cluster --attach-policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess --region us-east-1 --approve


kubectl apply -f networkpolicy.yaml
kubectl apply -f secretstore.yaml



cd lattice
kubectl apply -f gateway.yaml
kubectl apply -f gatewayclass.yaml
kubectl apply -f helthcheckroutepolicy.yaml
kubectl apply -f httproute.yaml



cd ../customer
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
sed -i -e "s/wsc2024-db-cluster.cluster-cvuu26s24sdo.us-east-1.rds.amazonaws.com/$AWSrdsEndPoint/" ./deployment.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

cd ../product
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
sed -i -e "s/wsc2024-db-cluster.cluster-cvuu26s24sdo.us-east-1.rds.amazonaws.com/$AWSrdsEndPoint/" ./deployment.yaml

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

cd ../order
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml




cd ../lattice
kubectl delete -f gateway.yaml
kubectl delete -f gatewayclass.yaml
kubectl delete -f helthcheckroutepolicy.yaml
kubectl delete -f httproute.yaml

cd ../customer
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ../product
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ../order
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
