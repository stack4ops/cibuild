#!/bin/sh

## install cibuilder environment
## - dind for docker
## - k3d for remote|kubernetes driver and docker-less buildctl

set -eu

ORIG_PWD=$(pwd)

# certs and resources for buildkit remote
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
  
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_CA=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_CA=$(base64 -w 0 ./buildkit/certs/client/ca.pem)/g" .env
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_CERT=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_CERT=$(base64 -w 0 ./buildkit/certs/client/cert.pem)/g" .env
  sed -i "s/^CIBUILD_BUILD_BUILDKIT_CLIENT_KEY=.*/CIBUILD_BUILD_BUILDKIT_CLIENT_KEY=$(base64 -w 0 ./buildkit/certs/client/key.pem)/g" .env
}

# service account and restricted kubeconfig for kubernetes driver: namespace buildkitk(ubernetes)
create_buildkitk_namespace() {
  
  if [ -f ./buildkit/kubeconfig ]; then
    rm ./buildkit/kubeconfig
  fi

  ./kc.sh apply -f buildkit/buildkitk-sa.yaml

  # create kubeconfig for buildkit service account
  K8S_CA=$(./kc.sh config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  # API endpoint only usable from within cibuilder-net!
  K8S_SERVER="https://k3d-cibuilder-serverlb:6443"
  # for testing from host change the server entry in ./buildkit/kubeconfig:
  # K8S_SERVER="https://127.0.0.1:6445"
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
  # for testing from host: K8S_SERVER="https://127.0.0.1:6445"
  USER_TOKEN=$(./kc.sh create token teststage-sa --namespace teststage --duration=8760h)

  cp ./teststage/kubeconfig.template ./teststage/kubeconfig
  sed -i "s|K8S_CA|${K8S_CA}|g" ./teststage/kubeconfig
  sed -i "s|K8S_SERVER|${K8S_SERVER}|g" ./teststage/kubeconfig
  sed -i "s|USER_TOKEN|${USER_TOKEN}|g" ./teststage/kubeconfig

  sed -i "s|^CIBUILD_TEST_SERVICE_ACCOUNT=.*|CIBUILD_TEST_SERVICE_ACCOUNT=$(base64 -w 0 ./teststage/kubeconfig)|g" .env
    
  . ./.env
}

create_cluster() {
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
}

prepare() {

  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  cd ${script_dir}

  # clear command cache
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
    echo "Copied .env.template to .env. Please customize .env if needed."
    echo "In most cases .env works out of the box."
    echo "For libs development set USE_REPO_LIBS=1"
  fi

  path=$(pwd)
  libpath="${path%/*}/bin"
  sed -i "s|^LIB_PATH=.*|LIB_PATH=${libpath}|g" .env
  . ./.env

  # generate Attic token secret if NIX_ENABLED and not yet set
  if [ "${NIX_ENABLED:-0}" = "1" ]; then
    if ! grep -q "^ATTIC_TOKEN_SECRET=.\+" .env; then
      ATTIC_TOKEN_SECRET=$(openssl rand -hex 32)
      sed -i "s|^ATTIC_TOKEN_SECRET=.*|ATTIC_TOKEN_SECRET=${ATTIC_TOKEN_SECRET}|g" .env
      echo "Generated ATTIC_TOKEN_SECRET"
    fi
  fi
}

install() {
  if [ ! -d ~/.local/bin ]; then
    echo "Creating ~/.local/bin"
    mkdir -p ~/.local/bin
  fi

  cp cibuild ~/.local/bin
  chmod 755 ~/.local/bin/cibuild

  if ! command -v cibuild >/dev/null 2>&1; then
    echo "Please add ~/.local/bin/ to your PATH variable."
    exit 1
  fi

  if [ ! -d ~/.config/cibuild ]; then
    echo "Creating ~/.config/cibuild"
    mkdir -p ~/.config/cibuild
  fi

  # pull and start containers
  docker pull      ${CIBUILDER_IMAGE}:${CIBUILDER_REF}
  docker volume    inspect ${COMPOSE_PROJECT_NAME}-registry-data > /dev/null 2>&1 || docker volume  create ${COMPOSE_PROJECT_NAME}-registry-data
  docker network   inspect ${COMPOSE_PROJECT_NAME}-net           > /dev/null 2>&1 || docker network create ${COMPOSE_PROJECT_NAME}-net
  
  if [ "${DIND_ENABLED}" = "1" ]; then
    docker volume inspect ${COMPOSE_PROJECT_NAME}-dind-data > /dev/null 2>&1 || docker volume create ${COMPOSE_PROJECT_NAME}-dind-data
    docker pull docker.io/library/docker:dind
    docker compose -f docker-compose.dind.yaml down
    docker compose -f docker-compose.dind.yaml up -d
  else
    docker compose -f docker-compose.min.yaml down
    docker compose -f docker-compose.min.yaml up -d
  fi

  # Attic Nix Binary Cache — independent of DIND
  if [ "${NIX_ENABLED:-0}" = "1" ]; then
    echo "==> Setting up Attic Nix Binary Cache..."

    docker volume inspect ${COMPOSE_PROJECT_NAME}-attic-storage > /dev/null 2>&1 || docker volume create ${COMPOSE_PROJECT_NAME}-attic-storage
    docker volume inspect ${COMPOSE_PROJECT_NAME}-attic-db      > /dev/null 2>&1 || docker volume create ${COMPOSE_PROJECT_NAME}-attic-db

    docker pull ghcr.io/zhaofengli/attic:latest
    docker compose -f docker-compose.attic.yaml down
    docker compose -f docker-compose.attic.yaml up -d

    # wait for healthy
    echo "    waiting for attic..."
    ATTIC_CONTAINER="${COMPOSE_PROJECT_NAME}-attic"
    tries=0
    while [ $tries -lt 30 ]; do
      status=$(docker inspect "${ATTIC_CONTAINER}" --format='{{.State.Health.Status}}' 2>/dev/null || echo "starting")
      [ "$status" = "healthy" ] && break
      tries=$((tries + 1))
      sleep 2
    done

    # generate token if not already set
    if ! grep -q "^CIBUILD_NIX_CACHE_TOKEN=" .env || grep -q "^CIBUILD_NIX_CACHE_TOKEN=$" .env; then
      ATTIC_TOKEN=$(docker exec "${ATTIC_CONTAINER}" \
        atticd make-token \
          --sub "cibuilder" \
          --validity "52w" \
          --push "nixpkgs" \
          --pull "nixpkgs" \
          --create-cache "nixpkgs" \
          --configure-cache "nixpkgs" \
        2>/dev/null)

      # create cache bucket
      docker exec "${ATTIC_CONTAINER}" \
        attic login local http://localhost:8080 "${ATTIC_TOKEN}" > /dev/null 2>&1 || true
      docker exec "${ATTIC_CONTAINER}" \
        attic cache create nixpkgs > /dev/null 2>&1 || true

      sed -i "s|^CIBUILD_NIX_CACHE_TOKEN=.*|CIBUILD_NIX_CACHE_TOKEN=${ATTIC_TOKEN}|g" .env
      echo "    token generated and written to .env"
    fi

    echo "    Attic ready at http://127.0.0.1:${ATTIC_PORT} (host)"
    echo "    Attic ready at http://${COMPOSE_PROJECT_NAME}-attic:8080 (within cibuilder-net)"
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
    echo "namespace teststage not found, creating..."
    create_teststage_namespace
  fi

  if ! ./kc.sh get namespace buildkitr >/dev/null 2>&1; then
    echo "namespace buildkitr not found, creating..."
    create_buildkitr_namespace
  fi

  if ! ./kc.sh get namespace buildkitk >/dev/null 2>&1; then
    echo "namespace buildkitk not found, creating..."
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
    sed -i "s/^CIBUILD_RELEASE_COSIGN_PRIVATE_KEY=.*/CIBUILD_RELEASE_COSIGN_PRIVATE_KEY=$(base64 -w 0 ./signing/cosign.key)/g" .env
    sed -i "s/^CIBUILD_RELEASE_COSIGN_PUBLIC_KEY=.*/CIBUILD_RELEASE_COSIGN_PUBLIC_KEY=$(base64 -w 0 ./signing/cosign.pub)/g" .env
  fi
}

finish() {
  cp .env ~/.config/cibuild/.env
  chmod 755 ~/.config/cibuild/.env
  echo ""
  echo "----------------------"
  echo "installed successfully!"
  echo ""
  echo "Registry UI: http://localhost:${REGISTRY_BROWSER_PORT}"
  if [ "${NIX_ENABLED:-0}" = "1" ]; then
    echo "Attic cache: http://127.0.0.1:${ATTIC_PORT}"
  fi
  echo ""
  cd ${ORIG_PWD}
}

prepare
install
finish