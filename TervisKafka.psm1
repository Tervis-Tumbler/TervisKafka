#Requires -version 5.0
#Requires -modules PasswordstatePowershell, TervisChocolatey, TervisNetTCPIP
#Requires -RunAsAdministrator

function Invoke-KafkaBrokerProvision {
    param (
        $EnvironmentName
    )
    Invoke-ClusterApplicationProvision -ClusterApplicationName KafkaBroker -EnvironmentName $EnvironmentName
    $Nodes = Get-TervisClusterApplicationNode -ClusterApplicationName KafkaBroker -EnvironmentName $EnvironmentName
    $Nodes | Invoke-ProcessKafkaTemplateFiles
    New-KafkaBrokerGPO
    $Nodes | Invoke-NodeGPUpdate
    $Nodes | Set-KafkaServicesToAumaticStart
}

function Set-KafkaServicesToAumaticStart {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Set-Service -StartupType Automatic -Name kafka-zookeeper-service -ComputerName $ComputerName
        Set-Service -StartupType Automatic -Name kafka-service -ComputerName $ComputerName
    }
}

function Invoke-ProcessKafkaTemplateFiles {
    param (
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$ComputerName,
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]$EnvironmentName
    )
    begin {
        $KafakChocolateyPackageTools = "C:\ProgramData\chocolatey\lib\kafka\tools\"
        $KafkaModulePath = (Get-Module -ListAvailable TervisKafka).ModuleBase
        $KafkaHomeTemplateFilesPath = "$KafkaModulePath\KafkaHome"
        $ZookeeperDataDirectoryTemplateFilesPath = "$KafkaModulePath\ZookeeperDataDirectory"
        $ZookeeperDataDirectory = "C:\tmp\zookeeper"
    }
    process {
        $Nodes = Get-TervisClusterApplicationNode -ClusterApplicationName KafkaBroker -EnvironmentName $EnvironmentName
        $NodeNumber = $Nodes.ComputerName.IndexOf($ComputerName) + 1
        $dataDir = "C:/tmp/zookeeper"

        $TemplateVariables = @{
            "broker.id" = $NodeNumber
            "log.dirs" = "C:/tmp/kafka-logs"
            dataDir = $dataDir
            ZookeeperNodeNames = $Nodes.ComputerName
        }

        $KafakChocolateyPackageToolsRemote = $KafakChocolateyPackageTools | ConvertTo-RemotePath -ComputerName $ComputerName
        $KafakHomeRemote = Get-ChildItem -Directory -Path $KafakChocolateyPackageToolsRemote | select -ExpandProperty FullName
        Invoke-ProcessTemplatePath -Path $KafkaHomeTemplateFilesPath -DestinationPath $KafakHomeRemote -TemplateVariables $TemplateVariables
        
        $ZookeeperDataDirectoryRemote = $ZookeeperDataDirectory | ConvertTo-RemotePath -ComputerName $ComputerName
        Invoke-ProcessTemplatePath -Path $ZookeeperDataDirectoryTemplateFilesPath -DestinationPath $ZookeeperDataDirectoryRemote -TemplateVariables @{NodeNumber=$NodeNumber}
    }
}

function New-KafkaNodePSSession {
    New-ApplicationNodePSSession -ClusterApplicationName KafkaBroker
}

function Get-KafkaLog {
    param (
        $ComputerName,

        [ValidateSet("controller","kafka-authorizer","kafka-request","log-cleaner","server","state-change")]
        $LogType
    )

    $KafkaHome = Get-ChildItem -Directory  "\\$ComputerName\C$\ProgramData\chocolatey\lib\kafka\tools\"
    get-content -Tail 300 -Path "$($KafkaHome.FullName)\logs\$LogType.log"
}

function Remove-KafkaData {
    param (
        [Alias("Name")]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        $ComputerName
    )
    begin { Stop-Kafka }
    process {    
        Remove-Item "\\$ComputerName\$(${log.dirs} -replace ":","$")" -Recurse    
    }
}

function Remove-ZookeperData {
    param (
        [Alias("Name")]
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        $ComputerName
    )
    begin { Stop-KafkaZookeeper }
    process {
        Remove-Item "\\$ComputerName\$($dataDir -replace ":","$")" -Recurse
    }
}

function New-KafkaBrokerGPO {
    $KafkaBrokerFirewallGPO = Get-GPO -Name "KafkaBrokerFirewall"
    if (-not $KafkaBrokerFirewallGPO) {    
        $KafkaBrokerFirewallGPO = New-GPO -Name "KafkaBrokerFirewall"
    
        $KafkaBrokerOU = Get-ADOrganizationalUnit -Filter {Name -eq "KafkaBroker"}
        $KafkaBrokerFirewallGPO | New-GPLink -Target $KafkaBrokerOU
        $ADDomain = Get-ADDomain
        $GPOSession = Open-NetGPO –PolicyStore "$($ADDomain.DNSRoot)\KafkaBrokerFirewall"
        New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Zookeeper -DisplayName Kafka-Zookeeper -Direction Inbound -LocalPort 2181,2888,3888 -Protocol TCP -Action Allow -Group Kafka
        New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Broker -DisplayName Kafka-Broker -Direction Inbound -LocalPort 9092 -Protocol TCP -Action Allow -Group Kafka
        Save-NetGPO -GPOSession $GPOSession

        Remove-NetFirewallRule -GPOSession $GPOSession -Name zookeeper
        Save-NetGPO -GPOSession $GPOSession
    }
}

function Get-KafkaZookeeperMyId {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    begin {
        $MyIdPath = "C:\tmp\zookeeper\myid"
    }
    process {
        $MyIdPathRemote = $MyIdPath | ConvertTo-RemotePath -ComputerName $ComputerName
        $ComputerName
        Get-Content -Path $MyIdPathRemote
    }
}

function Start-KafkaZookeeper {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Start-ServiceOnNode -ComputerName $ComputerName -Name kafka-zookeeper-service
    }
}

function Stop-KafkaZookeeper {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Stop-ServiceOnNode -ComputerName $ComputerName -Name kafka-zookeeper-service
    }
}

function Start-Kafka {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Start-ServiceOnNode -ComputerName $ComputerName -Name kafka-service
    }
}

function Stop-Kafka {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Stop-ServiceOnNode -ComputerName $ComputerName -Name kafka-service
    }
}

function Get-KafkaHome {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName = "localhost",
        [Switch]$AsRemotePath
    )
    $KafakChocolateyPackageToolsPath = "C:\ProgramData\chocolatey\lib\kafka\tools\"
    $KafkaHome = Invoke-Command -ComputerName $ComputerName  -ScriptBlock {
        Get-ChildItem -Directory -Path $Using:KafakChocolateyPackageToolsPath | 
        select -ExpandProperty FullName
    }

    if ($AsRemotePath) {
        $KafkaHome | ConvertTo-RemotePath -ComputerName $ComputerName
    } else {
        $KafkaHome
    }

}

function Get-KafkaTopics {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        $KafkaHome = Get-KafkaHome -ComputerName $ComputerName
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            . "$Using:KafkaHome\bin\windows\kafka-topics.bat" --zookeeper "$($Using:ComputerName):2181" --list
        }
    }
}

function Get-KafkaZookeeperService {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {get-service | where name -match zoo}
    }
}

function Get-KafkaService {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {get-service | where name -match kafka-service}
    }
}

function Get-KafkaServiceNetTCPConnection {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {        
            Get-NetTCPConnection -LocalPort 9092
        }
    }
}

function Get-KafkaZookeeperStatus {
    param (
        [Parameter(ValueFromPipelineByPropertyName)]$ComputerName
    )
    process {
        $ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "srvr" -ErrorAction SilentlyContinue}
        $ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "mntr" -ErrorAction SilentlyContinue}
        $ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "isro" -ErrorAction SilentlyContinue}
    }
}

function Edit-KafkaServerProperties {
    param (
        $ComputerName
    )
    $KafkaHome = Get-ChildItem -Directory  "\\$ComputerName\C$\ProgramData\chocolatey\lib\kafka\tools\"
    Start-Process notepad++ "$($KafkaHome.FullName)\config\server.properties"
}

function Edit-KafkaZookeeperServerProperties {
    param (
        $ComputerName
    )
    $KafkaHome = Get-ChildItem -Directory  "\\$ComputerName\C$\ProgramData\chocolatey\lib\kafka\tools\"
    Start-Process notepad++ "$($KafkaHome.FullName)\config\zookeeper.properties"
}
