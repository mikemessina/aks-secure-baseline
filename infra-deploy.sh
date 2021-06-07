#! /usr/bin/env bash

### 1 - Prepare for the Cluster
#Generate cert
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out appgw.crt -keyout appgw.key -subj "/CN=bicycle.contoso.com/O=Contoso Bicycle"
openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:

export APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out traefik-ingress-internal-aks-ingress-contoso-com-tls.crt -keyout traefik-ingress-internal-aks-ingress-contoso-com-tls.key -subj "/CN=*.aks-ingress.contoso.com/O=Contoso Aks Ingress"
export AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt | base64 | tr -d '\n')

## Prep for Azure AD Integration
az login -t c4a5ff7a-f87c-4d21-a0d9-08a2ff3dbdc7 --allow-no-subscriptions
TENANTID_K8SRBAC=$(az account show --query tenantId -o tsv)

export subscription=757725bf-fa35-4bb8-9e7a-436e23d7e241
az account set -s ${subscription}
az account show

#Create cluster admin group
export AADOBJECTNAME_GROUP_CLUSTERADMIN="AKS Admin TEST"
# export AADOBJECTID_GROUP_CLUSTERADMIN=$(az ad group show --display-name $AADOBJECTNAME_GROUP_CLUSTERADMIN --mail-nickname $AADOBJECTNAME_GROUP_CLUSTERADMIN --description "Principals in this group are cluster admins in the bu0001a000800 cluster." --query objectId -o tsv)
export AADOBJECTID_GROUP_CLUSTERADMIN=$(az ad group show --group "AKS Admin TEST" --query objectId -o tsv)

#Create break glass cluster admin acct.
export TENANTDOMAIN_K8SRBAC=$(az ad signed-in-user show --query 'userPrincipalName' -o tsv | cut -d '@' -f 2 | sed 's/\"//')
export AADOBJECTNAME_USER_CLUSTERADMIN="mac-aks-lab-admin"
# export AADOBJECTID_USER_CLUSTERADMIN=$(az ad user create --display-name=${AADOBJECTNAME_USER_CLUSTERADMIN} --user-principal-name ${AADOBJECTNAME_USER_CLUSTERADMIN}@${TENANTDOMAIN_K8SRBAC} --force-change-password-next-login --password ChangeMebu0001a0008AdminChangeMe --query objectId -o tsv)
export AADOBJECTID_USER_CLUSTERADMIN=$(az ad sp create-for-rbac --name=${AADOBJECTNAME_USER_CLUSTERADMIN} --skip-assignment --query objectId -o tsv)

az ad group member add -g $AADOBJECTID_GROUP_CLUSTERADMIN --member-id $AADOBJECTID_USER_CLUSTERADMIN ##Unable to add spn to aad group.

### 2 - Build The Target Network

## Deploy Hub and Spoke Networking

# [This takes less than one minute to run.] Used as hub for lab (rg-enterprise-networking-hubs)
az group create -n ACE-P-LAB-AKS-RGP-07-002 -l centralus

# [This takes less than one minute to run.] Used as the spokes for lab (rg-enterprise-networking-spokes)
az group create -n ACE-P-LAB-AKS-RGP-07-003 -l centralus

# [This takes about five minutes to run.]
az deployment group create -g ACE-P-LAB-AKS-RGP-07-002 -f networking/hub-default.json -p location=eastus2

RESOURCEID_VNET_HUB=$(az deployment group show -g ACE-P-LAB-AKS-RGP-07-002 -n hub-default --query properties.outputs.hubVnetId.value -o tsv)

# [This takes about five minutes to run.]
az deployment group create -g ACE-P-LAB-AKS-RGP-07-003 -f networking/spoke-BU0001A0008.json -p location=eastus2 hubVnetResourceId="${RESOURCEID_VNET_HUB}"

RESOURCEID_SUBNET_NODEPOOLS=$(az deployment group show -g ACE-P-LAB-AKS-RGP-07-003 -n spoke-BU0001A0008 --query properties.outputs.nodepoolSubnetResourceIds.value -o tsv)

# [This takes about three minutes to run.]
az deployment group create -g ACE-P-LAB-AKS-RGP-07-002 -f networking/hub-regionA.json -p location=eastus2 nodepoolSubnetResourceIds="['${RESOURCEID_SUBNET_NODEPOOLS}']"

### 3 - Deploy the AKS Cluster

# [This takes less than one minute.]
az group create --name ACE-P-LAB-AKS-RGP-07-005 --location eastus2

RESOURCEID_VNET_CLUSTERSPOKE=$(az deployment group show -g ACE-P-LAB-AKS-RGP-07-003 -n spoke-BU0001A0008 --query properties.outputs.clusterVnetResourceId.value -o tsv)

# [This takes about 15 minutes.]
az deployment group create -g ACE-P-LAB-AKS-RGP-07-005 -f cluster-stamp1.json -p targetVnetResourceId=${RESOURCEID_VNET_CLUSTERSPOKE} clusterAdminAadGroupObjectId=${AADOBJECTID_GROUP_CLUSTERADMIN} k8sControlPlaneAuthorizationTenantId=${TENANTID_K8SRBAC} appGatewayListenerCertificate=${APP_GATEWAY_LISTENER_CERTIFICATE} aksIngressControllerCertificate=${AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64}

# # Create an Azure Service Principal
# az ad sp create-for-rbac --name "github-workflow-aks-cluster" --sdk-auth --skip-assignment >sp.json
# export APP_ID=$(grep -oP '(?<="clientId": ").*?[^\\](?=",)' sp.json)
# # Wait for propagation
# until az ad sp show --id ${APP_ID} &>/dev/null; do echo "Waiting for Azure AD propagation" && sleep 5; done
# # Assign built-in Contributor RBAC role for creating resource groups and performing deployments at subscription level
# az role assignment create --assignee $APP_ID --role 'Contributor'
# # Assign built-in User Access Administrator RBAC role since granting RBAC access to other resources during the cluster creation will be required at subscription level (e.g. AKS-managed Internal Load Balancer, ACR, Managed Identities, etc.)
# az role assignment create --assignee $APP_ID --role 'User Access Administrator'
## Place the cluster under GitOps Management
