#!/bin/bash
set -euo pipefail

echo -e " \033[33;5m    __  _          _        ___                            \033[0m"
echo -e " \033[33;5m    \\ \\(_)_ __ ___( )__    / _ \\__ _ _ __ __ _  __ _  ___  \033[0m"
echo -e " \033[33;5m     \\ \\ | '_ \` _ \\/ __|  / /_\\/ _\` | '__/ _\` |/ _\` |/ _ \\ \033[0m"
echo -e " \033[33;5m  /\\_/ / | | | | | \\__ \\ / /_\\\\  (_| | | | (_| | (_| |  __/ \033[0m"
echo -e " \033[33;5m  \\___/|_|_| |_| |_|___/ \\____/\\__,_|_|  \\__,_|\\__, |\\___| \033[0m"
echo -e " \033[33;5m                                               |___/       \033[0m"
echo -e " \033[36;5m         _  _________   ___         _        _ _           \033[0m"
echo -e " \033[36;5m        | |/ |__ / __| |_ _|_ _  __| |_ __ _| | |          \033[0m"
echo -e " \033[36;5m        | ' < |_ \\__ \\  | || ' \\(_-|  _/ _\` | | |          \033[0m"
echo -e " \033[36;5m        |_|\\_|___|___/ |___|_||_/__/\\__\\__,_|_|_|          \033[0m"
echo -e " \033[32;5m             https://youtube.com/@jims-garage              \033[0m"

#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################

# Versions
KVVERSION="v0.6.3"
k3sVersion="v1.26.10+k3s2"

# Nodes
master1=192.168.86.86
master2=192.168.86.87
master3=192.168.86.88
worker1=192.168.86.89
worker2=192.168.86.90

user=ubuntu
interface=eth0
vip=192.168.86.91
lbrange=192.168.86.100-192.168.86.150

masters=($master2 $master3)
workers=($worker1 $worker2)
all=($master1 $master2 $master3 $worker1 $worker2)
allnomaster1=($master2 $master3 $worker1 $worker2)

certName=id_rsa
config_file=~/.ssh/config

# ---- Disk thresholds (adjust as you like) ----
MIN_ROOT_TOTAL_GB=15   # require at least 15G root filesystem total
MIN_ROOT_FREE_GB=6     # and at least 6G free on /
MIN_TMP_FREE_MB=512    # and at least 512M free on /tmp

#############################################
#            DO NOT EDIT BELOW              #
#############################################

# Convert thresholds to KiB for df -Pk comparisons
MIN_ROOT_TOTAL_KB=$((MIN_ROOT_TOTAL_GB * 1024 * 1024))
MIN_ROOT_FREE_KB=$((MIN_ROOT_FREE_GB * 1024 * 1024))
MIN_TMP_FREE_KB=$((MIN_TMP_FREE_MB * 1024))

red()   { echo -e " \033[31;5m$*\033[0m"; }
green() { echo -e " \033[32;5m$*\033[0m"; }
yellow(){ echo -e " \033[33;5m$*\033[0m"; }

# Time sanity
sudo timedatectl set-ntp off || true
sudo timedatectl set-ntp on  || true

# Move SSH certs to ~/.ssh and perms
mkdir -p /home/$user/.ssh
cp /home/$user/{$certName,$certName.pub} /home/$user/.ssh || true
chmod 600 /home/$user/.ssh/$certName 2>/dev/null || true
chmod 644 /home/$user/.ssh/$certName.pub 2>/dev/null || true

# k3sup
if ! command -v k3sup >/dev/null 2>&1; then
    yellow "k3sup not found, installing"
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
else
    green "k3sup already installed"
fi

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
    yellow "kubectl not found, installing"
    curl -fsSL -o kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    green "kubectl already installed"
fi

# SSH config (insecure: skip host key checking)
if [ ! -f "$config_file" ]; then
  echo "StrictHostKeyChecking no" > "$config_file"
  chmod 600 "$config_file"
else
  if grep -q "^StrictHostKeyChecking" "$config_file"; then
    sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$config_file"
  else
    echo "StrictHostKeyChecking no" >> "$config_file"
  fi
fi

# Copy our key to nodes
for node in "${all[@]}"; do
  ssh-copy-id -i /home/$user/.ssh/$certName.pub $user@$node
done

# ---- Preflight: ensure space on every host ----
fail_nodes=()

check_node_space () {
  local node="$1"
  # remote check in KiB
  if ! ssh -i /home/$user/.ssh/$certName $user@"$node" bash -s -- <<EOF
set -e
read -r RT RF <<< "\$(df -Pk /   | awk 'NR==2{print \$2" "\$4}')"
read -r TT TF <<< "\$(df -Pk /tmp | awk 'NR==2{print \$2" "\$4}')"
ERR=0
if [ "\$RT" -lt "$MIN_ROOT_TOTAL_KB" ]; then
  echo "ERROR($node): / total=\$((RT/1024/1024))G < ${MIN_ROOT_TOTAL_GB}G required"; ERR=1; fi
if [ "\$RF" -lt "$MIN_ROOT_FREE_KB" ]; then
  echo "ERROR($node): / free =\$((RF/1024/1024))G < ${MIN_ROOT_FREE_GB}G required"; ERR=1; fi
if [ "\$TF" -lt "$MIN_TMP_FREE_KB" ]; then
  echo "ERROR($node): /tmp free=\$((TF/1024))M < ${MIN_TMP_FREE_MB}M required"; ERR=1; fi
exit \$ERR
EOF
  then
    fail_nodes+=("$node")
  else
    green "Disk OK on $node"
  fi
}

yellow "Running disk preflight checks..."
for node in "${all[@]}"; do
  check_node_space "$node"
done

if [ "${#fail_nodes[@]}" -ne 0 ]; then
  red  "Preflight failed on: ${fail_nodes[*]}"
  echo "Fix disk sizing (root and /tmp) on those nodes, then re-run."
  exit 1
fi
green "All nodes meet disk requirements."

# Install policycoreutils on each node (as in original)
for newnode in "${all[@]}"; do
  ssh -i /home/$user/.ssh/$certName $user@$newnode sudo NEEDRESTART_MODE=a apt-get update -y
  ssh -i /home/$user/.ssh/$certName $user@$newnode sudo NEEDRESTART_MODE=a apt-get install -y policycoreutils
  green "PolicyCoreUtils installed on $newnode"
done

# Step 1: Bootstrap first k3s node
mkdir -p ~/.kube
k3sup install \
  --ip $master1 \
  --user $user \
  --tls-san $vip \
  --cluster \
  --k3s-version $k3sVersion \
  --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$master1 --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
  --merge \
  --sudo \
  --local-path "$HOME/.kube/config" \
  --ssh-key "/home/$user/.ssh/$certName" \
  --context k3s-ha
green "First node bootstrapped successfully!"

export KUBECONFIG="$HOME/.kube/config"

# Wait for API & CoreDNS before we apply CRDs/manifests
yellow "Waiting for apiserver..."
until kubectl get --raw='/readyz' >/dev/null 2>&1; do sleep 3; done
yellow "Waiting for node Ready + CoreDNS..."
kubectl wait node --all --for=condition=Ready --timeout=5m
kubectl -n kube-system wait deploy/coredns --for=condition=Available --timeout=5m || true
kubectl -n kube-system get pods

# Step 2: Kube-VIP RBAC
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml

# Step 3: kube-vip manifest
curl -fsSLo "$HOME/kube-vip" https://raw.githubusercontent.com/LoSTOPerativE/JimsGarage/main/Kubernetes/K3S-Deploy/kube-vip
sed "s/\$interface/$interface/g; s/\$vip/$vip/g" "$HOME/kube-vip" > "$HOME/kube-vip.yaml"

# Step 4/5: place kube-vip manifest on master1
scp -i /home/$user/.ssh/$certName "$HOME/kube-vip.yaml" $user@$master1:~/kube-vip.yaml
ssh -i /home/$user/.ssh/$certName $user@$master1 "sudo mkdir -p /var/lib/rancher/k3s/server/manifests && sudo mv ~/kube-vip.yaml /var/lib/rancher/k3s/server/manifests/kube-vip.yaml"

# Step 6: join masters
for newnode in "${masters[@]}"; do
  k3sup join \
    --ip $newnode \
    --user $user \
    --sudo \
    --k3s-version $k3sVersion \
    --server \
    --server-ip $master1 \
    --ssh-key "/home/$user/.ssh/$certName" \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$newnode --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --server-user $user
  green "Master $newnode joined successfully!"
done

# add workers
for newagent in "${workers[@]}"; do
  k3sup join \
    --ip $newagent \
    --user $user \
    --sudo \
    --k3s-version $k3sVersion \
    --server-ip $master1 \
    --ssh-key "/home/$user/.ssh/$certName" \
    --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""
  green "Agent $newagent joined successfully!"
done

# Wait for cluster to settle
yellow "Waiting for cluster to settle..."
kubectl wait node --all --for=condition=Ready --timeout=10m || true

# Step 7: kube-vip cloud provider
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml

# Step 8: MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# ipAddressPool from your repo
curl -fsSLo "$HOME/ipAddressPool" https://raw.githubusercontent.com/LoSTOPerativE/JimsGarage/main/Kubernetes/K3S-Deploy/ipAddressPool
sed "s/\$lbrange/$lbrange/g" "$HOME/ipAddressPool" > "$HOME/ipAddressPool.yaml"
kubectl apply -f "$HOME/ipAddressPool.yaml"

# Step 9: Test with Nginx
kubectl apply -f https://raw.githubusercontent.com/inlets/inlets-operator/master/contrib/nginx-sample-deployment.yaml -n default
kubectl -n default expose deployment nginx-1 --port=80 --type=LoadBalancer || true

yellow "Waiting for K3S to sync and LoadBalancer to come online"
kubectl -n default wait deploy/nginx-1 --for=condition=Available --timeout=5m || true

# Step 10: Ensure metallb controller ready and l2Advertisement
kubectl -n metallb-system wait --for=condition=Ready pod -l component=controller --timeout=120s || true
kubectl apply -f "$HOME/ipAddressPool.yaml"
kubectl apply -f https://raw.githubusercontent.com/LoSTOPerativE/JimsGarage/main/Kubernetes/K3S-Deploy/l2Advertisement.yaml

kubectl get nodes -o wide
kubectl get svc -A
kubectl get pods -A -o wide

green "Happy Kubing! Access Nginx via its EXTERNAL-IP above."
