#!/bin/sh

## uninstall cibuilder environment
## keep registry volumes 

set -eu

. ./.env

ORIG_PWD=$(pwd)

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd ${script_dir}

purge=0
case "${1:-}" in
  --all|-a)
    purge=1
    ;;
esac

# stop docker compose
echo "stop docker compose"
if [ "${DIND_ENABLED}" = "1" ]; then
  docker compose -f docker-compose.dind.yaml down
else
  docker compose -f docker-compose.min.yaml down  
fi

# delete k3d cluster cibuilder
echo "remove k3d cluster"
k3d cluster delete cibuilder

if [ -f kubeconfig ]; then
  echo "delete kubeconfig"
  rm kubeconfig
fi

if [ -f  ./buildkit/kubeconfig ]; then
  echo "delete ./buildkit/kubeconfig"
  rm ./buildkit/kubeconfig
fi

if [ -d  ./buildkit/certs ]; then
  echo "delete ./buildkit/certs"
  rm -r ./buildkit/certs
fi

if [ -f  ./buildkit/client-certs.yaml ]; then
  echo "delete ./buildkit/client-certs.yaml"
  rm ./buildkit/client-certs.yaml
fi

if [ -f  ./buildkit/daemon-certs.yaml ]; then
  echo "delete ./buildkit/daemon-certs.yaml"
  rm ./buildkit/daemon-certs.yaml
fi

if [ -f  ./teststage/kubeconfig ]; then
  echo "delete ./teststage/kubeconfig"
  rm ./teststage/kubeconfig
fi

if [ -f ~/.local/bin/cibuild ]; then
  echo "delete ~/.local/bin/cibuild"
fi

if [ -d ~/.config/cibuild ]; then
  echo "remove ~/.config/cibuild"
  rm -r ~/.config/cibuild
fi

if [ $purge -eq 1 ]; then
  echo "purge volumes"
  docker volume rm cibuilder-registry-data
  if [ "${DIND_ENABLED}" = "1" ]; then
    docker volume rm cibuilder-dind-data
  fi
  echo "if you want to update kubectl on next installation remove the binary manually"
fi

cd ${ORIG_PWD}