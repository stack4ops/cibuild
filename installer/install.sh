#!/bin/sh

## install cibuilder environment
## - dind for docker
## - k3d for remote|kubernetes driver and docker-less buildctl

set -eu

ORIG_PWD=$(pwd)

# globals
# API_PORT=6445
# LOCAL_LIBS_MOUNT -v PATH_TO_CIBUILD_REPO/cibuild/bin:${HOME}/bin

find_free_port() {
  min=1001
  max=9000

  find_free_port_tries=0
  find_free_port_max_tries=100

  local_host=127.0.0.1

  while :; do
    free_port=$(( (RANDOM % (max - min + 1)) + min ))
    nc -z -w 1 "${local_host}" "${free_port}" || break

    find_free_port_tries=$((find_free_port_tries + 1))
    if [ $find_free_port_tries -eq $find_free_port_max_tries ]; then
      echo "no free port found"
      exit 1
    fi
  done

  echo $free_port
}

# certs and ressources for buildkit remote
create_buildkitr_namespace() {
  
  ./kc.sh create namespace buildkitr

  if [ -d ./buildkit/certs ]; then
    rm -r ./buildkit/certs
  fi

  # make certs
  mkdir -p buildkit/certs buildkit/certs/daemon buildkit/certs/client
  curl -JLO "https://dl.filippo.io/mkcert/latest?for=${os_arch}"
  mv mkcert-* buildkit/certs/mkcert
  chmod +x buildkit/certs/mkcert
  cd buildkit/certs
  
  # for internal ClusterIP access
  SAN="buildkitr.default.svc.cluster.local buildkitr.buildkitr.svc.cluster.local k3d-cibuilder-server-0 127.0.0.1"
  SAN_CLIENT=client
  (
    echo $SAN | tr " " "\n" >SAN
    CAROOT=$(pwd) ./mkcert -cert-file daemon/cert.pem -key-file daemon/key.pem ${SAN} >/dev/null 2>&1
    CAROOT=$(pwd) ./mkcert -client -cert-file client/cert.pem -key-file client/key.pem ${SAN_CLIENT} >/dev/null 2>&1
    cp -f rootCA.pem daemon/ca.pem
    cp -f rootCA.pem client/ca.pem
    rm -f rootCA.pem rootCA-key.pem
  )
  cd ../../

  ./kubectl create secret generic buildkit-daemon-certs --dry-run=client -o yaml --from-file=./buildkit/certs/daemon > buildkit/daemon-certs.yaml
  ./kubectl create secret generic buildkit-client-certs --dry-run=client -o yaml --from-file=./buildkit/certs/client > buildkit/client-certs.yaml
  ./kc.sh apply -f buildkit/daemon-certs.yaml -n buildkitr
  ./kc.sh apply -f ./buildkit/client-certs.yaml -n buildkitr
  ./kc.sh apply -f ./buildkit/buildkitr-deploy.yaml -n buildkitr
  
  #cp -r ./buildkit/certs/client ~/.config/cibuild/
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_CA=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_CA=$(base64 -w 0 ./buildkit/certs/client/ca.pem)/g" .env
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_CERT=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_CERT=$(base64 -w 0 ./buildkit/certs/client/cert.pem)/g" .env
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_KEY=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_KEY=$(base64 -w 0 ./buildkit/certs/client/key.pem)/g" .env
}

# serviceaccount and restricted kubeconfig for kubernetes driver: namespace buildkitk(ubernetes)
create_buildkitk_namespace() {
  
  if [ -f ./buildkit/kubeconfig ]; then
    rm ./buildkit/kubeconfig
  fi

  ./kc.sh apply -f buildkit/buildkitk-sa.yaml

  # create kubeconfig for buildkit service account
  K8S_CA=$(./kc.sh config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  # API endpoint only usable from within cibuilder-net!
  K8S_SERVER="https://k3d-cibuilder-serverlb:6443"
  # for testing from host you have to change the server entry in ./buildkit/kubeconfig:
  #SERVER="https://127.0.0.1:6445"
  USER_TOKEN=$(./kc.sh create token buildkit-sa --namespace buildkitk --duration=8760h)

  cp ./buildkit/kubeconfig.template ./buildkit/kubeconfig
  sed -i "s|K8S_CA|${K8S_CA}|g" ./buildkit/kubeconfig
  sed -i "s|K8S_SERVER|${K8S_SERVER}|g" ./buildkit/kubeconfig
  sed -i "s|USER_TOKEN|${USER_TOKEN}|g" ./buildkit/kubeconfig

  sed -i "s/^CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT=.*/CIBUILD_BUILD_BUILDKIT_SERVICE_ACCOUNT=$(base64 -w 0 ./buildkit/kubeconfig)/g" .env
  
  . ./.env
}

create_teststage_namespace() {

  ./kc.sh apply -f teststage/teststage-sa.yaml

  if [ -f ./teststage/kubeconfig ]; then
    rm ./teststage/kubeconfig
  fi

  # create kubeconfig for teststage service account
  
  K8S_CA=$(./kc.sh config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  # API endpoint from within cibuilder-net
  K8S_SERVER="https://k3d-cibuilder-serverlb:6443"
  #SERVER="https://127.0.0.1:6445"
  USER_TOKEN=$(./kc.sh create token teststage-sa --namespace teststage --duration=8760h)

  cp ./teststage/kubeconfig.template ./teststage/kubeconfig
  sed -i "s|K8S_CA|${K8S_CA}|g" ./teststage/kubeconfig
  sed -i "s|K8S_SERVER|${K8S_SERVER}|g" ./teststage/kubeconfig
  sed -i "s|USER_TOKEN|${USER_TOKEN}|g" ./teststage/kubeconfig

  sed -i "s|^CIBUILD_TEST_SERVICE_ACCOUNT=.*|CIBUILD_TEST_SERVICE_ACCOUNT=$(base64 -w 0 ./teststage/kubeconfig)|g" .env
    
  . ./.env
}

create_cluster() {
  if [ "${FIND_FREE_PORTS}" = "1" ]; then
    API_PORT=$(find_free_port)
  fi
  k3d cluster create \
    "${COMPOSE_PROJECT_NAME}" \
    --network "${COMPOSE_PROJECT_NAME}-net" \
    --api-port 127.0.0.1:${API_PORT} \
    --registry-config ./registry.yaml \
    --kubeconfig-switch-context=false \
    --kubeconfig-update-default=false \
    --k3s-arg "--disable=traefik@server:0"
  if [ -f kubeconfig ]; then
    rm kubeconfig
  fi 
  if [ -f ./buildkit/kubeconfig ]; then
    rm ./buildkit/kubeconfig
  fi
  if [ -f ./teststage/kubeconfig ]; then
    rm ./teststage/kubeconfig
  fi 
  k3d kubeconfig get "${COMPOSE_PROJECT_NAME}" > kubeconfig
  #export KUBECONFIG=./kubeconfig
}

prepare() {

  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  cd ${script_dir}

  # remove command cache
  hash -r 2>/dev/null || true

  arch=$(uname -m)
  os_arch="linux/amd64"
  os_arch_min="amd64"

  case "$arch" in
      x86_64)
          os_arch="linux/amd64"
          os_arch_min="amd64"
          ;;
      aarch64 | arm64)
          os_arch="linux/arm64"
          os_arch_min="arm64"
          ;;
      *)
          echo "unknown architecture: $arch"
          exit 1
          ;;
  esac
  echo "os_arch: $os_arch"
  if [ ! -f ./.env ]; then
    cp ./.env.template .env
    echo "Copied .env.template to .env. Please customize .env variables to your needs."
    echo "In most cases .env works out of the box"
    echo "For libs development set USE_REPO_LIBS=1"
  fi
  path=$(pwd)
  libpath="${path%/*}/bin"
  sed -i "s|^LIB_PATH=.*|LIB_PATH=${libpath}|g" .env
  . ./.env
}

install() {
  if [ ! -d ~/.local/bin ]; then
    echo "create ~/.local/bin"
    mkdir -p ~/.local/bin
  fi

  cp cibuild ~/.local/bin
  chmod 755 ~/.local/bin/cibuild

  if ! command -v cibuild >/dev/null 2>&1; then
    echo "please add ~/.local/bin/ to your PATH variable."
    exit 1
  fi

  if [ ! -d ~/.config/cibuild ]; then
    echo "create ~/.config/cibuild"
    mkdir -p ~/.config/cibuild
  fi

  if [ "${FIND_FREE_PORTS}" = "1" ]; then
    if ! command -v nc >/dev/null 2>&1; then
      echo "please install nc (netcat)"
      exit 1
    fi
    p1=$(find_free_port)
    p2=$p1
    while [ "$p2" -eq "$p1" ]; do
      p2=$(find_free_port)
    done
    sed -i "s/^REGISTRY_PORT=.*/REGISTRY_PORT=$p1/g" .env
    sed -i "s/^REGISTRY_BROWSER_PORT=.*/REGISTRY_BROWSER_PORT=$p2/g" .env
    . ./.env
  fi

  # pull and start container
  docker pull      ${CIBUILDER_IMAGE}:${CIBUILDER_REF}
  docker volume    inspect ${COMPOSE_PROJECT_NAME}-registry-data > /dev/null 2>&1 || docker volume  create ${COMPOSE_PROJECT_NAME}-registry-data
  docker network   inspect ${COMPOSE_PROJECT_NAME}-net           > /dev/null 2>&1 || docker network create ${COMPOSE_PROJECT_NAME}-net
  
  if [ "${DIND_ENABLED}" = "1" ]; then
    docker volume inspect ${COMPOSE_PROJECT_NAME}-dind-data > /dev/null 2>&1 || docker volume  create ${COMPOSE_PROJECT_NAME}-dind-data
    docker pull docker.io/library/docker:dind
    docker compose -f docker-compose.dind.yaml down
    docker compose -f docker-compose.dind.yaml up -d
  else
    docker compose  -f docker-compose.min.yaml down
    docker compose -f docker-compose.min.yaml up -d
  fi

  if ! command -v k3d >/dev/null 2>&1; then
    wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  fi

  k3d cluster list | grep -q "${COMPOSE_PROJECT_NAME}" || create_cluster

  if [ ! -f './kubectl' ]; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod 755 './kubectl'
  fi

  ./kc.sh cluster-info

  if ! ./kc.sh get namespace teststage >/dev/null 2>&1; then
    echo "namespace teststage not exists, creating ..."
    create_teststage_namespace
  fi

  if ! ./kc.sh get namespace buildkitr >/dev/null 2>&1; then
    echo "namespace buildkitr not exists, creating ..."
    create_buildkitr_namespace
  fi

  if ! ./kc.sh get namespace buildkitk >/dev/null 2>&1; then
    echo "namespace buildkitk not exists, creating ..."
    create_buildkitk_namespace
  fi

  # cosign
  if [ ! -f './cosign' ]; then
    curl -L https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${os_arch_min} >cosign
    chmod +x './cosign'
  fi

  if [ ! -d "./signing" ]; then
    mkdir "./signing"
  fi

  if [ ! -f "signing/codesign.key" ] || [ ! -f "signing/codesign.pub" ]; then
      export COSIGN_PASSWORD="" && ./cosign generate-key-pair
      mv cosign.key ./signing/
      mv cosign.pub ./signing/
      sed -i "s/^CIBUILD_DEPLOY_COSIGN_PRIVATE_KEY=.*/CIBUILD_DEPLOY_COSIGN_PRIVATE_KEY=$(base64 -w 0 ./signing/cosign.key)/g" .env
      sed -i "s/^CIBUILD_DEPLOY_COSIGN_PUBLIC_KEY=.*/CIBUILD_DEPLOY_COSIGN_PUBLIC_KEY=$(base64 -w 0 ./signing/cosign.pub)/g" .env
  fi
  
}

finish() {
  cp .env ~/.config/cibuild/.env
  chmod 755 ~/.config/cibuild/.env
  echo ""
  echo ""
  echo "----------------------"
  echo "installed successfully!"
  echo ""
  #echo "registry can be accessed: localhost:${REGISTRY_PORT}"
  echo "registry-ui can be accessed in your browser: http://localhost:${REGISTRY_BROWSER_PORT}"
  echo ""
  echo ""
  cd ${ORIG_PWD}
}

prepare
install
finish

