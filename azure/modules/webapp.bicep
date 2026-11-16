// App Service Web App 하나 (컨테이너). scrap-web, scrap-server, scrap-diagnosis, scrap-route 공통

param name string
param location string
param planId string
@description('Key Vault 참조를 읽을 관리 ID')
param identityId string
param subnetId string
param acrLoginServer string
param acrUser string
@secure()
param acrPassword string
param image string
param port int
param appSettings object = {}
param startupCommand string = ''
param healthPath string = ''
@description('Front Door ID. 값이 있으면 그 Front Door를 거친 요청만 받음 (scrap-web)')
param frontDoorId string = ''
@description('값이 있으면 이 서브넷(VNet 안의 앱)에서 오는 요청만 받음 (내부 앱)')
param allowSubnetId string = ''

var inbound = !empty(frontDoorId) ? [
  {
    name: 'front-door'
    action: 'Allow'
    priority: 100
    tag: 'ServiceTag'
    ipAddress: 'AzureFrontDoor.Backend'
    headers: { 'x-azure-fdid': [frontDoorId] }
  }
] : (!empty(allowSubnetId) ? [
  {
    name: 'vnet-apps'
    action: 'Allow'
    priority: 100
    vnetSubnetResourceId: allowSubnetId
  }
] : [])

var baseSettings = {
  WEBSITES_PORT: string(port)
  WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
  DOCKER_REGISTRY_SERVER_URL: 'https://${acrLoginServer}'
  DOCKER_REGISTRY_SERVER_USERNAME: acrUser
  DOCKER_REGISTRY_SERVER_PASSWORD: acrPassword
  // ACR에 같은 태그로 새 이미지가 올라오면 웹훅으로 다시 받음
  DOCKER_ENABLE_CI: 'true'
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  kind: 'app,linux,container'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    serverFarmId: planId
    httpsOnly: true
    keyVaultReferenceIdentity: identityId
    virtualNetworkSubnetId: subnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${image}'
      appCommandLine: startupCommand
      alwaysOn: true
      healthCheckPath: empty(healthPath) ? null : healthPath
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      ipSecurityRestrictions: inbound
      ipSecurityRestrictionsDefaultAction: empty(inbound) ? 'Allow' : 'Deny'
      // 배포 웹훅(SCM)은 ACR이 부르므로 앱 접근 제한을 따르지 않음. SCM은 배포 자격 증명으로 보호됨
      scmIpSecurityRestrictionsUseMain: false
      appSettings: [for s in items(union(baseSettings, appSettings)): { name: s.key, value: s.value }]
    }
  }
}

// ACR 웹훅이 SCM에 기본 인증으로 들어오도록 허용
resource scmAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: site
  name: 'scm'
  properties: { allow: true }
}

output id string = site.id
output name string = site.name
output defaultHost string = site.properties.defaultHostName
