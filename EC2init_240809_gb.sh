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


#GB

AWSuserID=$(aws sts get-caller-identity --query "Account" --output text)
AWSprvA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-app-a --query "Subnets[0].SubnetId" --output text)
AWSprvB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-app-b --query "Subnets[0].SubnetId" --output text)
AWSpubA=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-public-a --query "Subnets[0].SubnetId" --output text)
AWSpubB=$(aws ec2 describe-subnets --filter Name=tag:Name,Values=wsi-public-b --query "Subnets[0].SubnetId" --output text)
AWSalbsgID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=wsi-app-alb-sg" --query "SecurityGroups[*].GroupId" --output text)


sed -i -e "s/subnet-0c0630619772d1ea5/$AWSprvA/" ./cluster.yaml
sed -i -e "s/subnet-02cf55e1d0fca28f8/$AWSprvB/" ./cluster.yaml
sed -i -e "s/702661606257/$AWSuserID/" ./cluster.yaml


cd eks
eksctl create cluster -f cluster.yaml

kubectl apply -f ns.yaml



helm repo add projectcalico https://docs.tigera.io/calico/charts
echo '{ installation: {kubernetesProvider: EKS }}' > values.yaml
kubectl create namespace tigera-operator
helm install calico projectcalico/tigera-operator --version v3.28.1 --namespace tigera-operator
helm install calico projectcalico/tigera-operator --version v3.28.1 -f values.yaml --namespace tigera-operator
watch kubectl get pods -n calico-system


helm repo add external-secrets https://charts.external-secrets.io

helm install external-secrets \
   external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
	--set installCRDs=true
watch kubectl get pods -n external-secrets

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


eksctl create iamserviceaccount --name secretmanager --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/secrets_manager_full_access --region ap-northeast-2 --approve
eksctl create iamserviceaccount --name dynamodb --namespace wsi --cluster wsi-eks-cluster --attach-policy-arn arn:aws:iam::$AWSuserID:policy/dynamodb-kms-policy --region ap-northeast-2 --approve


kubectl apply -f networkpolicy.yaml
kubectl apply -f secretstore.yaml



cd logging
kubectl apply -f loggingns.yaml
kubectl apply -f fluentd.yaml
kubectl apply -f flunetbit.yaml



cd ../customer
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

cd ../product
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
kubectl apply -f secret.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

cd ../order
sed -i -e "s/702661606257/$AWSuserID/" ./deployment.yaml
kubectl apply -f fluentbitns.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f configmap.yaml



cd ../customer
kubectl delete -f secret.yaml
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ../product
kubectl delete -f secret.yaml
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml

cd ../order
kubectl delete -f deployment.yaml
kubectl delete -f service.yaml
kubectl delete -f configmap.yaml
kubectl delete -f fluentbitns.yaml

cd ~/eks
sed -i -e "s/subnet-0befd2a4363295c1b/$AWSpubA/" ./ingress.yaml
sed -i -e "s/subnet-0c122938cef92aeb3/$AWSpubB/" ./ingress.yaml
sed -i -e "s/sg-0d331899df9a95935/$AWSalbsgID/" ./ingress.yaml


kubectl apply -f ingress.yaml





docker tag customer:latest 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/customer-ecr:latest
docker tag product:latest 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/product-ecr:latest
docker tag order:latest 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/order-ecr:latest

docker push 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/customer-ecr:latest
docker push 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/product-ecr:latest
docker push 690677342176.dkr.ecr.ap-northeast-2.amazonaws.com/order-ecr:latest