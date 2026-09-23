param location string = resourceGroup().location
param projectName string = 'scanlyed'
param diEndpoint string = 'https://cloud25ai-di-4d98c.cognitiveservices.azure.com/'
@secure()
param diKey string
param alertEmail string


// Create an Azure Container Registry (ACR) for storing container images
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${projectName}acr'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// Create a Log Analytics workspace for monitoring and logging
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${projectName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Create an Azure Container Apps environment for hosting containerized applications
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${projectName}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Create an Azure Container App that will run the containerized application
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${projectName}-app'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'di-key'
          value: diKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'scanlyapi'
          image: '${acr.properties.loginServer}/scanlyapi:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'AZURE_DI_ENDPOINT'
              value: diEndpoint
            }
            {
              name: 'AZURE_DI_KEY'
              secretRef: 'di-key'
            }
            {
              name: 'AZURE_STORAGE_URL'
              value: storage.properties.primaryEndpoints.blob
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
          ]
        }
      ]
      scale: {
        minReplicas: 2
        maxReplicas: 3
      }
    }
  }
}

// Create an Azure Storage account for storing application data
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${projectName}storage'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// Grant the Container App's managed identity permission to read/write blobs in the storage account
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, containerApp.id, 'StorageBlobDataContributor')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${projectName}-insights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${projectName}-alerts-ag'
  location: 'global'
  properties: {
    groupShortName: 'scanlyAG'
    enabled: true
    emailReceivers: [
      {
        name: 'TeamEmail'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource errorAlertRule 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: '${projectName}-di-error-alert'
  location: location
  properties: {
    severity: 2
    enabled: true
    scopes: [
      logAnalytics.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL | where ContainerAppName_s == \'${projectName}-app\' | where Log_s contains "fail: Program"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}
