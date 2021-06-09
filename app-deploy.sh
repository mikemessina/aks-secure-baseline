RESOURCE_GROUP_NAME=ACE-P-LAB-AKS-RGP-07-005
AKS_CLUSTER_NAME=$(az deployment group show -g $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.aksClusterName.value -o tsv)

az aks get-credentials -g $RESOURCE_GROUP_NAME -n $AKS_CLUSTER_NAME

kubectl get nodes

# Get your ACR cluster name
ACR_NAME=$(az deployment group show -g $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.containerRegistryName.value -o tsv)

# Import cluster management images hosted in public container registries
az acr import --source docker.io/library/memcached:1.5.20 -n $ACR_NAME
az acr import --source docker.io/fluxcd/flux:1.21.1 -n $ACR_NAME
az acr import --source docker.io/weaveworks/kured:1.6.1 -n $ACR_NAME

# Verify the user you logged in with has the appropriate permissions. This should result in a
# "yes" response. If you receive "no" to this command, check which user you authenticated as
# and ensure they are assigned to the Azure AD Group you designated for cluster admins.
kubectl auth can-i create namespace -A

kubectl create namespace cluster-baseline-settings

kubectl delete -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/cluster-manifests/cluster-baseline-settings/flux.yaml
kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/cluster-manifests/cluster-baseline-settings/flux.yaml

kubectl create -f flux.yaml

kubectl wait -n cluster-baseline-settings --for=condition=ready pod --selector=app.kubernetes.io/name=flux --timeout=90s

KEYVAULT_NAME=$(az deployment group show --resource-group $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.keyVaultName.value -o tsv)
# az keyvault set-policy --certificate-permissions import list get --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt traefik-ingress-internal-aks-ingress-contoso-com-tls.key >traefik-ingress-internal-aks-ingress-contoso-com-tls.pem
az keyvault certificate import -f traefik-ingress-internal-aks-ingress-contoso-com-tls.pem -n traefik-ingress-internal-aks-ingress-contoso-com-tls --vault-name $KEYVAULT_NAME

# az keyvault delete-policy --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

kubectl get constrainttemplate

export TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID=$(az deployment group show --resource-group $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.aksIngressControllerPodManagedIdentityResourceId.value -o tsv)
export TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az deployment group show --resource-group $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.aksIngressControllerPodManagedIdentityClientId.value -o tsv)

# press Ctrl-C once you receive a successful response
kubectl get ns a0008 -w

cat <<EOF | kubectl create -f -
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentity
metadata:
  name: podmi-ingress-controller-identity
  namespace: a0008
spec:
  type: 0
  resourceID: $TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID
  clientID: $TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID
---
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentityBinding
metadata:
  name: podmi-ingress-controller-binding
  namespace: a0008
spec:
  azureIdentity: podmi-ingress-controller-identity
  selector: podmi-ingress-controller
EOF

# KEYVAULT_NAME=$(az deployment group show --resource-group $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.keyVaultName.value -o tsv)

#
cat <<EOF | kubectl create -f -
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: aks-ingress-contoso-com-tls-secret-csi-akv
  namespace: a0008
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    keyvaultName: $KEYVAULT_NAME
    objects:  |
      array:
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.crt
          objectType: cert
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.key
          objectType: secret
    tenantId: $TENANTID_AZURERBAC
EOF

# Get your ACR cluster name
ACR_NAME=$(az deployment group show -g $RESOURCE_GROUP_NAME -n cluster-stamp1 --query properties.outputs.containerRegistryName.value -o tsv)

# Import ingress controller image hosted in public container registries
az acr import --source docker.io/library/traefik:v2.4.8 -n $ACR_NAME

# kubectl delete -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/traefik.yaml
# kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/traefik.yaml
kubectl create -f traefik.yaml

kubectl wait -n a0008 --for=condition=ready pod --selector=app.kubernetes.io/name=traefik-ingress-ilb --timeout=90s

kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/aspnetapp.yaml
# kubectl delete -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/aspnetapp.yaml

kubectl wait -n a0008 --for=condition=ready pod --selector=app.kubernetes.io/name=aspnetapp --timeout=90s

kubectl get ingress aspnetapp-ingress -n a0008

kubectl run curl -n a0008 -i --tty --rm --image=mcr.microsoft.com/azure-cli --limits='cpu=200m,memory=128Mi'

# From within the open shell
curl -kI https://bu0001a0008-00.aks-ingress.contoso.com -w '%{remote_ip}\n'
exit
