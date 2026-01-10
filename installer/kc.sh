#!/bin/sh
if [ ! -x "./kubectl" ] || [ ! -f "./kubeconfig" ]; then
    echo "run install.sh first"
    exit 1
fi

exec kubectl --kubeconfig kubeconfig "$@"