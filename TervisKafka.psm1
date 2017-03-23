#Requires -version 5.0
#Requires -modules PasswordstatePowershell, TervisChocolatey, TervisNetTCPIP
#Requires -RunAsAdministrator

function Get-KafkaNodes {
    Get-TervisClusterApplicationNode -ClusterApplicationName KafkaBroker -ExludeVM
}

function Get-KafkaVM {
    Find-TervisVM -Name $(Get-KafkaNodeNames)
}

function Get-KafakVMNetworkAdapter {
    Get-KafkaVM | select -ExpandProperty VMNetworkAdapter
}

function Invoke-KafkaBrokerProvision {
    Invoke-ClusterApplicationProvision -ClusterApplicationName KafkaBroker

    $TervisKafkaModulePath = (Get-Module -ListAvailable TervisKafka).ModuleBase

    foreach ($VMVMNetworkAdapter in $KafakVMVMNetworkAdapters) {

        $NodeNumber = $KafakVMVMNetworkAdapters.IndexOf($VMVMNetworkAdapter) + 1
        $KafkaHome = Get-ChildItem -Directory  "\\$($VMVMNetworkAdapter.VMName)\C$\ProgramData\chocolatey\lib\kafka\tools\"
        ${broker.id} = $NodeNumber

        "$TervisKafkaModulePath\server.properties.pstemplate" | Invoke-ProcessTemplateFile |
        Out-File -Encoding utf8 -NoNewline "$($KafkaHome.FullName)\config\server.properties"

        $ZookeeperNodeNames = $KafakVMVMNetworkAdapters.vmname

        "$TervisKafkaModulePath\zookeeper.properties.pstemplate" | Invoke-ProcessTemplateFile |
        Out-File -Encoding ascii -NoNewline "$($KafkaHome.FullName)\config\zookeeper.properties"

        $ZookeeperDataDirOnNode = "\\$($VMVMNetworkAdapter.VMName)\$($dataDir -replace ":","$")"
        New-Item -ItemType Directory $ZookeeperDataDirOnNode -Force

        $NodeNumber | Out-File -Force "$ZookeeperDataDirOnNode\myid" -Encoding ascii -NoNewline
    }    
}


${log.dirs} = "C:/tmp/kafka-logs"
$dataDir = "C:/tmp/zookeeper"

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
    }
    
    $KafkaBrokerOU = Get-ADOrganizationalUnit -Filter {Name -eq "KafkaBroker"}
    $KafkaBrokerFirewallGPO | New-GPLink -Target $KafkaBrokerOU
    $ADDomain = Get-ADDomain
    $GPOSession = Open-NetGPO –PolicyStore "$($ADDomain.DNSRoot)\KafkaBrokerFirewall"
    New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Zookeeper -DisplayName Kafka-Zookeeper -Direction Inbound -LocalPort 2181,2888,3888 -Protocol TCP -Action Allow -Group Kafka
    New-NetFirewallRule -GPOSession $GPOSession -Name Kafka-Broker -DisplayName Kafka-Broker -Direction Inbound -LocalPort 9092 -Protocol TCP -Action Allow -Group Kafka
    Save-NetGPO -GPOSession $GPOSession

    Remove-NetFirewallRule -GPOSession $GPOSession -Name zookeeper
    Save-NetGPO -GPOSession $GPOSession
    $KafakVMVMNetworkAdapters.vmname | % { Invoke-GPUpdate -Computer $_ -RandomDelayInMinutes 0}
}

function Get-KafkaZookeeperMyId {
    $Sessions = New-KafakNodePSSession
    Invoke-Command -Session $Sessions -ScriptBlock {hostname;get-content "C:\tmp\zookeeper\myid"}
}

function Start-KafkaZookeeper {
    param (
        $Sessions = $(New-KafakNodePSSession)
    )
    Invoke-Command -Session $Sessions -ScriptBlock {Start-Service kafka-zookeeper-service}
}

function Stop-KafkaZookeeper {
    param (
        $Sessions = $(New-KafakNodePSSession)
    )
    Invoke-Command -Session $Sessions -ScriptBlock {Stop-Service kafka-zookeeper-service}
}

function Start-Kafka {
    param (
        $Sessions = $(New-KafakNodePSSession)
    )
    Invoke-Command -Session $Sessions -ScriptBlock {Start-Service kafka-service}
}

function Stop-Kafka {
    param (
        $Sessions = $(New-KafakNodePSSession)
    )
    Invoke-Command -Session $Sessions -ScriptBlock {Stop-Service kafka-service}
}

function Get-KafkaTopics {
    start-process "$($KafkaHome.FullName)\bin\windows\kafka-topics.bat" "--zookeeper $($KafakVMVMNetworkAdapters.vmname[0]):2181"
}

function Get-KafkaZookeeperService {
    Invoke-Command -Session $Sessions -ScriptBlock {get-service | where name -match zoo}
}

function Get-KafkaService {
    param (
        $Sessions = $(New-KafakNodePSSession)
    )

    Invoke-Command -Session $Sessions -ScriptBlock {get-service | where name -match kafka-service}
}

function Get-KafkaServiceNetTCPConnection {
    Invoke-Command -Session $Sessions -ScriptBlock {        
        Get-NetTCPConnection -LocalPort 9092
    }
}

function Get-KafkaZookeeperStatus {    
    $Sessions.ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "srvr" -ErrorAction SilentlyContinue}
    $Sessions.ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "mntr" -ErrorAction SilentlyContinue}
    $Sessions.ComputerName | % {$_; Send-NetworkData -Computer $_ -Port 2181 -Data "isro" -ErrorAction SilentlyContinue}
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
    Start-Process notepad++ "$($KafkaHome.FullName)\config\server.properties"
}
