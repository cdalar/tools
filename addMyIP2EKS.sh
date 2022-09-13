#!/bin/bash
EKS_CLUSTER_NAME=$(kubectl config current-context | awk -F'/' '{print $NF}')
echo $EKS_CLUSTER_NAME
MYIP=$(curl -s 'https://api.ipify.org?format=json' | jq -r .ip | awk '{print $1 "/32"}')
echo $MYIP
IPS=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --region=eu-central-1 | jq --arg MYIP "$MYIP" -r '.cluster.resourcesVpcConfig.publicAccessCidrs + [$MYIP] | join(",")')
aws eks update-cluster-config --region "eu-central-1" --name $EKS_CLUSTER_NAME --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs=$IPS
