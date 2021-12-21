#!/bin/bash
while getopts n: flag
do
    case "${flag}" in
        n) namespace=${OPTARG};;
    esac
done

if [[ -z "$namespace" ]]; then
  echo "Namespace is required";
  echo "Usage: $0 -n <namespace>";
  exit 1;
fi

echo "Namespace: $namespace";

kubectl proxy -p 8005 &
# Delete NS 
kubectl get ns $namespace -o json | \
  jq '.spec.finalizers=[]' | \
  curl -X PUT http://localhost:8005/api/v1/namespaces/$namespace/finalize -H "Content-Type: application/json" --data @-
