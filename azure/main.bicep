// SCRAP 정식 배포 (App Service + PostgreSQL Flexible Server + Front Door)
// 아키텍처: https://claude.ai/artifact/FjtcQ6VkrhDsGx5sRHTXGb
// 실행은 deploy/azure/deploy.sh가 함 (docs/deploy-azure.md)
//
// 구독 권한이 리소스 그룹 기여자뿐이라 역할 할당을 쓰지 않음
//   - 이미지: ACR 관리자 계정으로 가져옴
//   - 비밀값: Key Vault 액세스 정책에 앱용 관리 ID를 넣어 읽음
//   - 배포: ACR에 같은 태그(main)로 이미지가 올라오면 웹훅으로 App Service가 다시 받음
//
// 두 단계로 배포함
//   deployApps=false: 네트워크, DB, Key Vault, ACR, 관리 ID, 모니터링
//   deployApps=true : 위 + App Service 플랜·앱 4개·배포 웹훅 + Front Door/WAF + 앱 경고

targetScope = 'resourceGroup'

// 부트캠프 구독 제한: App Service 할당량이 Korea Central에만 있고, 관리형 PostgreSQL은 어느 지역에서도 만들 수 없음
param location string = 'koreacentral'
param prefix string = 'scrap'
param deployApps bool = false
@description('App Service가 따라가는 이미지 태그. 이 태그로 push하면 다시 배포됨')
param imageTag string = 'main'

@description('Key Vault에 비밀값을 넣는 사람의 Entra 개체 ID (az ad signed-in-user show --query id)')
param deployerObjectId string

// 부트캠프 구독은 관리형 PostgreSQL(Flexible Server)을 만들 수 없어(SkuNotAvailable) VNet 안의 VM에서 Docker로 띄움
@secure()
param postgresAdminPassword string
param postgresAdminUser string = 'scrapadmin'
param postgresImage string = 'postgres:17'
param dbVmSize string = 'Standard_B2s'
@description('DB VM 관리용 SSH 공개 키. 공용 IP가 없어 평소에는 az vm run-command로 관리함')
param dbVmSshPublicKey string
param appServiceSku string = 'B2'

@description('직접 산 도메인. 비우면 Front Door 기본 주소를 씀')
param customHost string = ''

param diagnosisOpenAiEndpoint string = ''
param diagnosisOpenAiDeployment string = ''
param diagnosisOpenAiApiVersion string = '2024-10-21'
param routeOpenAiEndpoint string = ''
param routeOpenAiDeployment string = ''

param googleClientId string = ''
param microsoftClientId string = ''
param microsoftTenant string = 'common'

@description('WAF: IP 하나가 1분에 보낼 수 있는 요청 수')
param wafRateLimitPerMinute int = 1000
@description('경고 메일 받을 주소. 비우면 경고를 만들지 않음')
param alertEmail string = ''

// 지역을 바꾸면 이름도 바뀌게 함 (지운 Key Vault·PostgreSQL 이름은 한동안 다시 쓸 수 없음)
var suffix = take(uniqueString(resourceGroup().id, location), 6)
// App Service 이름은 전 세계에서 하나여야 해서 뒤에 고유 문자열을 붙임
var appNames = {
  web: '${prefix}-web-${suffix}'
  server: '${prefix}-server-${suffix}'
  diagnosis: '${prefix}-diagnosis-${suffix}'
  route: '${prefix}-route-${suffix}'
}

// ---------- 모니터링 ----------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${prefix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${prefix}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------- 네트워크 ----------
// 새 VNet은 기본 인터넷 출구가 없어 NAT 게이트웨이로 나감 (앱의 Azure OpenAI 호출, DB VM의 이미지 받기)
resource natIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${prefix}-nat'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-01-01' = {
  name: 'nat-${prefix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: natIp.id }]
    idleTimeoutInMinutes: 10
  }
}

// DB는 앱 서브넷에서 오는 5432만 받음
resource dbNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: 'nsg-${prefix}-db'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-apps-postgres'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.0.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '5432'
        }
      }
      {
        name: 'deny-other-vnet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: 'vnet-${prefix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        // App Service VNet 통합. 내부 앱은 이 서브넷에서 오는 요청만 받음
        name: 'snet-apps'
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: [{ name: 'appservice', properties: { serviceName: 'Microsoft.Web/serverFarms' } }]
          serviceEndpoints: [{ service: 'Microsoft.Web' }]
          natGateway: { id: nat.id }
        }
      }
      {
        name: 'snet-db'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: { id: dbNsg.id }
          natGateway: { id: nat.id }
        }
      }
    ]
  }
}

var appsSubnetId = vnet.properties.subnets[0].id

// ---------- PostgreSQL (DB VM) ----------
var dbHost = '10.0.2.4'

// 처음 부팅할 때 Docker를 설치하고 PostgreSQL을 띄움. scrap_server는 POSTGRES_DB로, scrap_engine은 초기화 SQL로 만듦
var dbCloudInit = '''
#cloud-config
package_update: true
packages: [docker.io]
write_files:
  - path: /opt/scrap-db/init/01-databases.sql
    content: |
      CREATE DATABASE scrap_engine;
  - path: /opt/scrap-db/env
    permissions: '0600'
    content: |
      POSTGRES_USER=__USER__
      POSTGRES_PASSWORD=__PASSWORD__
      POSTGRES_DB=scrap_server
runcmd:
  - systemctl enable --now docker
  - docker run -d --name postgres --restart unless-stopped -p 5432:5432 --env-file /opt/scrap-db/env -v /opt/scrap-db/init:/docker-entrypoint-initdb.d:ro -v pgdata:/var/lib/postgresql/data __IMAGE__
'''

resource dbNic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: 'nic-${prefix}-db'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: vnet.properties.subnets[1].id }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dbHost
        }
      }
    ]
  }
}

resource dbVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-${prefix}-db'
  location: location
  properties: {
    hardwareProfile: { vmSize: dbVmSize }
    osProfile: {
      computerName: 'scrap-db'
      adminUsername: 'azureuser'
      customData: base64(replace(replace(replace(dbCloudInit, '__USER__', postgresAdminUser), '__PASSWORD__', postgresAdminPassword), '__IMAGE__', postgresImage))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/azureuser/.ssh/authorized_keys', keyData: dbVmSshPublicKey }] }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [{ id: dbNic.id }] }
  }
}

// ---------- 이미지 저장소 ----------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'cr${prefix}${suffix}'
  location: location
  // Basic은 웹훅이 2개까지라 앱 4개의 배포 웹훅을 만들 수 없음
  sku: { name: 'Standard' }
  properties: { adminUserEnabled: true }
}

// ---------- 앱이 Key Vault를 읽을 때 쓰는 관리 ID ----------
resource appId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${prefix}-apps'
  location: location
}

// ---------- 비밀값 ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${prefix}-${suffix}'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: deployerObjectId
        permissions: { secrets: ['get', 'list', 'set', 'delete', 'recover'] }
      }
      {
        tenantId: subscription().tenantId
        objectId: appId.properties.principalId
        permissions: { secrets: ['get', 'list'] }
      }
    ]
  }
}

func kvRef(vaultName string, secret string) string => '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=${secret})'

// ---------- Front Door ----------
resource fd 'Microsoft.Cdn/profiles@2024-02-01' = if (deployApps) {
  name: 'afd-${prefix}'
  location: 'global'
  sku: { name: 'Standard_AzureFrontDoor' }
}

resource fdEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = if (deployApps) {
  parent: fd
  name: '${prefix}-${suffix}'
  location: 'global'
  properties: { enabledState: 'Enabled' }
}

var publicHost = !empty(customHost) ? customHost : (deployApps ? fdEndpoint.properties.hostName : '')
var publicUrl = 'https://${publicHost}'
var internalUrl = {
  server: 'https://${appNames.server}.azurewebsites.net'
  diagnosis: 'https://${appNames.diagnosis}.azurewebsites.net'
  route: 'https://${appNames.route}.azurewebsites.net'
}

// ---------- App Service ----------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = if (deployApps) {
  name: 'asp-${prefix}'
  location: location
  kind: 'linux'
  sku: { name: appServiceSku }
  properties: { reserved: true }
}

module diagnosis 'modules/webapp.bicep' = if (deployApps) {
  name: 'app-diagnosis'
  params: {
    location: location
    planId: plan.id
    identityId: appId.id
    subnetId: appsSubnetId
    acrLoginServer: acr.properties.loginServer
    acrUser: acr.listCredentials().username
    acrPassword: acr.listCredentials().passwords[0].value
    name: appNames.diagnosis
    image: '${acr.properties.loginServer}/scrap-diagnosis:${imageTag}'
    port: 8030
    healthPath: '/health'
    allowSubnetId: appsSubnetId
    startupCommand: 'sh -c "alembic upgrade head && uvicorn app.main:app --host 0.0.0.0 --port 8030"'
    appSettings: {
      APP_ENV: 'prod'
      DATABASE_URL: kvRef(kv.name, 'diagnosis-database-url')
      DB_CREATE_ALL: 'false'
      ENGINE_SERVICE_TOKEN: kvRef(kv.name, 'engine-service-token')
      LLM_PROVIDER: empty(diagnosisOpenAiEndpoint) ? 'off' : 'azure'
      AZURE_OPENAI_ENDPOINT: diagnosisOpenAiEndpoint
      AZURE_OPENAI_DEPLOYMENT: diagnosisOpenAiDeployment
      AZURE_OPENAI_API_VERSION: diagnosisOpenAiApiVersion
      AZURE_OPENAI_API_KEY: kvRef(kv.name, 'diagnosis-openai-key')
    }
  }
  dependsOn: [dbVm]
}

module route 'modules/webapp.bicep' = if (deployApps) {
  name: 'app-route'
  params: {
    location: location
    planId: plan.id
    identityId: appId.id
    subnetId: appsSubnetId
    acrLoginServer: acr.properties.loginServer
    acrUser: acr.listCredentials().username
    acrPassword: acr.listCredentials().passwords[0].value
    name: appNames.route
    image: '${acr.properties.loginServer}/scrap-route:${imageTag}'
    port: 8000
    allowSubnetId: appsSubnetId
    appSettings: {
      SCRAP_INTAKE_SERVICE_TOKEN: kvRef(kv.name, 'intake-service-token')
      AZURE_OPENAI_ENDPOINT: routeOpenAiEndpoint
      AZURE_OPENAI_DEPLOYMENT: routeOpenAiDeployment
      AZURE_OPENAI_API_KEY: kvRef(kv.name, 'route-openai-key')
    }
  }
}

module server 'modules/webapp.bicep' = if (deployApps) {
  name: 'app-server'
  params: {
    location: location
    planId: plan.id
    identityId: appId.id
    subnetId: appsSubnetId
    acrLoginServer: acr.properties.loginServer
    acrUser: acr.listCredentials().username
    acrPassword: acr.listCredentials().passwords[0].value
    name: appNames.server
    image: '${acr.properties.loginServer}/scrap-server:${imageTag}'
    port: 8000
    healthPath: '/health'
    allowSubnetId: appsSubnetId
    appSettings: {
      APP_ENV: 'prod'
      DOCS_ENABLED: 'false'
      DATABASE_URL: kvRef(kv.name, 'server-database-url')
      // DB VM은 VNet 안에서만 접속하고 TLS를 쓰지 않음
      DB_SSL: 'disable'
      JWT_SECRET: kvRef(kv.name, 'jwt-secret')
      SESSION_SECRET: kvRef(kv.name, 'session-secret')
      BACKEND_URL: publicUrl
      FRONTEND_URL: publicUrl
      // 화면이 nginx를 거쳐 같은 주소로 API를 부르므로 CORS 설정은 두지 않음
      // ('['로 시작하는 값은 배포 엔진이 수식으로 해석해 깨짐)
      COOKIE_SECURE: 'true'
      GOOGLE_CLIENT_ID: googleClientId
      GOOGLE_CLIENT_SECRET: kvRef(kv.name, 'google-client-secret')
      MICROSOFT_CLIENT_ID: microsoftClientId
      MICROSOFT_CLIENT_SECRET: kvRef(kv.name, 'microsoft-client-secret')
      MICROSOFT_TENANT: microsoftTenant
      DIAGNOSIS_ENGINE_URL: internalUrl.diagnosis
      ENGINE_SERVICE_TOKEN: kvRef(kv.name, 'engine-service-token')
      AI_BASE_URL: internalUrl.route
      SCRAP_INTAKE_SERVICE_TOKEN: kvRef(kv.name, 'intake-service-token')
    }
  }
  dependsOn: [dbVm]
}

module web 'modules/webapp.bicep' = if (deployApps) {
  name: 'app-web'
  params: {
    location: location
    planId: plan.id
    identityId: appId.id
    subnetId: appsSubnetId
    acrLoginServer: acr.properties.loginServer
    acrUser: acr.listCredentials().username
    acrPassword: acr.listCredentials().passwords[0].value
    name: appNames.web
    image: '${acr.properties.loginServer}/scrap-web:${imageTag}'
    port: 80
    frontDoorId: deployApps ? fd.properties.frontDoorId : ''
    appSettings: {
      SCRAP_SERVER_URL: internalUrl.server
    }
  }
}

// ACR에 <이미지>:<imageTag>가 push되면 App Service에 알림
var cd = {
  web: 'scrap-web'
  server: 'scrap-server'
  diagnosis: 'scrap-diagnosis'
  route: 'scrap-route'
}

// 같은 ACR에 웹훅을 동시에 만들면 충돌하므로 하나씩 만듦
@batchSize(1)
resource hooks 'Microsoft.ContainerRegistry/registries/webhooks@2023-07-01' = [for k in items(cd): if (deployApps) {
  parent: acr
  name: 'cd${k.key}'
  location: location
  properties: {
    serviceUri: '${list(resourceId('Microsoft.Web/sites/config', appNames[k.key], 'publishingcredentials'), '2023-12-01').properties.scmUri}/api/registry/webhook'
    actions: ['push']
    scope: '${k.value}:${imageTag}'
    status: 'enabled'
  }
  dependsOn: [web, server, diagnosis, route]
}]

// ---------- Front Door 원본·경로·WAF ----------
resource fdOrigins 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = if (deployApps) {
  parent: fd
  name: 'web'
  properties: {
    loadBalancingSettings: { sampleSize: 4, successfulSamplesRequired: 3, additionalLatencyInMilliseconds: 50 }
    healthProbeSettings: { probePath: '/', probeRequestType: 'HEAD', probeProtocol: 'Https', probeIntervalInSeconds: 120 }
  }
}

resource fdOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = if (deployApps) {
  parent: fdOrigins
  name: 'scrap-web'
  properties: {
    hostName: '${appNames.web}.azurewebsites.net'
    originHostHeader: '${appNames.web}.azurewebsites.net'
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enforceCertificateNameCheck: true
  }
  dependsOn: [web]
}

// 직접 산 도메인. Azure 관리 인증서를 쓰고, DNS에 확인용 TXT(_dnsauth)와 CNAME을 넣어야 연결됨
resource fdDomain 'Microsoft.Cdn/profiles/customDomains@2024-02-01' = if (deployApps && !empty(customHost)) {
  parent: fd
  name: replace(customHost, '.', '-')
  properties: {
    hostName: customHost
    tlsSettings: { certificateType: 'ManagedCertificate', minimumTlsVersion: 'TLS12' }
  }
}

var fdCustomDomains = (deployApps && !empty(customHost)) ? [{ id: fdDomain.id }] : []

// API는 사용자별 응답이라 캐시하지 않음
resource fdRouteApi 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = if (deployApps) {
  parent: fdEndpoint
  name: 'api'
  properties: {
    originGroup: { id: fdOrigins.id }
    customDomains: fdCustomDomains
    patternsToMatch: ['/api/*']
    supportedProtocols: ['Http', 'Https']
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
  }
  dependsOn: [fdOrigin]
}

// 화면 파일은 원본(nginx)의 Cache-Control을 따라 캐시함
resource fdRouteWeb 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = if (deployApps) {
  parent: fdEndpoint
  name: 'web'
  properties: {
    originGroup: { id: fdOrigins.id }
    customDomains: fdCustomDomains
    patternsToMatch: ['/*']
    supportedProtocols: ['Http', 'Https']
    httpsRedirect: 'Enabled'
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    cacheConfiguration: {
      queryStringCachingBehavior: 'UseQueryString'
      compressionSettings: {
        isCompressionEnabled: true
        contentTypesToCompress: ['text/html', 'text/css', 'application/javascript', 'application/json', 'image/svg+xml']
      }
    }
  }
  dependsOn: [fdOrigin, fdRouteApi]
}

resource waf 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = if (deployApps) {
  name: 'waf${prefix}'
  location: 'global'
  sku: { name: 'Standard_AzureFrontDoor' }
  properties: {
    policySettings: { enabledState: 'Enabled', mode: 'Prevention' }
    customRules: {
      rules: [
        {
          name: 'RateLimitPerIp'
          priority: 100
          enabledState: 'Enabled'
          ruleType: 'RateLimitRule'
          rateLimitDurationInMinutes: 1
          rateLimitThreshold: wafRateLimitPerMinute
          groupBy: [{ variableName: 'SocketAddr' }]
          // 모든 요청에 적용
          matchConditions: [
            {
              matchVariable: 'RemoteAddr'
              operator: 'IPMatch'
              negateCondition: true
              matchValue: ['255.255.255.255/32']
            }
          ]
          action: 'Block'
        }
      ]
    }
  }
}

resource fdSecurity 'Microsoft.Cdn/profiles/securityPolicies@2024-02-01' = if (deployApps) {
  parent: fd
  name: 'waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: { id: waf.id }
      associations: [{ domains: concat([{ id: fdEndpoint.id }], fdCustomDomains), patternsToMatch: ['/*'] }]
    }
  }
}

// ---------- 경고 ----------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-${prefix}'
  location: 'global'
  properties: {
    groupShortName: prefix
    enabled: true
    emailReceivers: [{ name: 'team', emailAddress: alertEmail, useCommonAlertSchema: true }]
  }
}

resource pgCpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(alertEmail)) {
  name: 'alert-db-cpu'
  location: 'global'
  properties: {
    severity: 2
    enabled: true
    scopes: [dbVm.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'cpu'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
}

resource server5xxAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployApps && !empty(alertEmail)) {
  name: 'alert-server-5xx'
  location: 'global'
  properties: {
    severity: 2
    enabled: true
    scopes: [resourceId('Microsoft.Web/sites', appNames.server)]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'http5xx'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Http5xx'
          operator: 'GreaterThan'
          threshold: 10
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup.id }]
  }
  dependsOn: [server]
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output keyVaultName string = kv.name
output postgresHost string = dbHost
output postgresAdminUser string = postgresAdminUser
output publicUrl string = deployApps ? publicUrl : ''
output frontDoorHost string = deployApps ? fdEndpoint.properties.hostName : ''
output webHost string = deployApps ? '${appNames.web}.azurewebsites.net' : ''
@description('도메인 DNS에 넣을 값: TXT _dnsauth.<도메인> = 이 토큰, CNAME <도메인> = frontDoorHost')
output customDomainValidationToken string = (deployApps && !empty(customHost)) ? fdDomain.properties.validationProperties.validationToken : ''
output appNames object = appNames
