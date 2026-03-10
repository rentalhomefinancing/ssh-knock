# SSH Knock - Port Knocking GUI Client
# Placeholders replaced during server install:
#   __KNOCK1__, __KNOCK2__, __KNOCK3__ - knock sequence ports
#   __SSH_PORT__ - actual SSH port after knock
#   __HOSTNAME__ - server hostname/IP

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$knockPorts = @(__KNOCK1__, __KNOCK2__, __KNOCK3__)
$sshPort    = __SSH_PORT__

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SSH Knock"
    Width="420" Height="380"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Background="#0f172a">

    <Window.Resources>
        <Style x:Key="LabelStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#94a3b8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
        </Style>
        <Style x:Key="InputStyle" TargetType="TextBox">
            <Setter Property="Background" Value="#334155"/>
            <Setter Property="Foreground" Value="#f1f5f9"/>
            <Setter Property="BorderBrush" Value="#475569"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="CaretBrush" Value="#f1f5f9"/>
        </Style>
    </Window.Resources>

    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Title -->
        <StackPanel Grid.Row="0" Margin="0,0,0,18">
            <TextBlock Text="SSH Knock" FontSize="22" FontWeight="Bold" Foreground="#f1f5f9"/>
            <TextBlock Text="Port knocking client" FontSize="12" Foreground="#64748b" Margin="0,2,0,0"/>
        </StackPanel>

        <!-- Card -->
        <Border Grid.Row="1" Background="#1e293b" CornerRadius="8" Padding="16" Margin="0,0,0,14">
            <StackPanel>
                <TextBlock Text="Hostname / IP" Style="{StaticResource LabelStyle}"/>
                <TextBox Name="txtHost" Text="__HOSTNAME__" Style="{StaticResource InputStyle}" Margin="0,0,0,10"/>

                <TextBlock Text="SSH User" Style="{StaticResource LabelStyle}"/>
                <TextBox Name="txtUser" Text="root" Style="{StaticResource InputStyle}"/>
            </StackPanel>
        </Border>

        <!-- Button -->
        <Button Grid.Row="2" Name="btnKnock" Height="42" Margin="0,0,0,14"
                FontSize="15" FontWeight="Bold" Cursor="Hand"
                BorderThickness="0">
            <Button.Style>
                <Style TargetType="Button">
                    <Setter Property="Background" Value="#0ea5e9"/>
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="Button">
                                <Border Name="border" Background="{TemplateBinding Background}"
                                        CornerRadius="6" Padding="0,0,0,0">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="border" Property="Background" Value="#38bdf8"/>
                                    </Trigger>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="border" Property="Background" Value="#475569"/>
                                        <Setter Property="Foreground" Value="#94a3b8"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </Button.Style>
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x1F513; " FontSize="15" VerticalAlignment="Center"/>
                <TextBlock Text="Knock &amp; Connect" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
            </StackPanel>
        </Button>

        <!-- Status -->
        <Border Grid.Row="3" Background="#1e293b" CornerRadius="6" Padding="12,10" Margin="0,0,0,14" MinHeight="60">
            <TextBlock Name="txtStatus" Text="Ready." Foreground="#94a3b8" FontSize="12"
                       TextWrapping="Wrap" FontFamily="Consolas"/>
        </Border>

        <!-- Spacer -->
        <Grid Grid.Row="4"/>

        <!-- Knock sequence info -->
        <Border Grid.Row="5" Background="#1e293b" CornerRadius="6" Padding="10,8">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock Text="Sequence: " Foreground="#64748b" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Name="txtSequence" Foreground="#0ea5e9" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Text=" &#x2192; SSH " Foreground="#64748b" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Name="txtSshPort" Foreground="#22c55e" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtHost     = $window.FindName("txtHost")
$txtUser     = $window.FindName("txtUser")
$btnKnock    = $window.FindName("btnKnock")
$txtStatus   = $window.FindName("txtStatus")
$txtSequence = $window.FindName("txtSequence")
$txtSshPort  = $window.FindName("txtSshPort")

$txtSequence.Text = ($knockPorts -join " > ")
$txtSshPort.Text  = "$sshPort"

function Set-Status {
    param([string]$Message, [string]$Color = "#94a3b8")
    $window.Dispatcher.Invoke([Action]{
        $txtStatus.Text       = $Message
        $txtStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    })
}

function Send-Knock {
    param([string]$Host_, [int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($Host_, $Port, $null, $null)
        $result.AsyncWaitHandle.WaitOne(1500, $false) | Out-Null
        $tcp.Close()
    } catch {
        # Expected - knock ports typically reject/drop connections.
        # The SYN packet is what matters.
    }
}

$btnKnock.Add_Click({
    $hostname = $txtHost.Text.Trim()
    $user     = $txtUser.Text.Trim()

    if ([string]::IsNullOrEmpty($hostname)) {
        Set-Status "Error: Hostname is required." "#ef4444"
        return
    }
    if ([string]::IsNullOrEmpty($user)) {
        Set-Status "Error: SSH user is required." "#ef4444"
        return
    }

    $btnKnock.IsEnabled = $false

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("window", $window)
    $runspace.SessionStateProxy.SetVariable("knockPorts", $knockPorts)
    $runspace.SessionStateProxy.SetVariable("sshPort", $sshPort)
    $runspace.SessionStateProxy.SetVariable("hostname", $hostname)
    $runspace.SessionStateProxy.SetVariable("user", $user)
    $runspace.SessionStateProxy.SetVariable("btnKnock", $btnKnock)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        function Set-UIStatus {
            param([string]$Msg, [string]$Color = "#94a3b8")
            $window.Dispatcher.Invoke([Action]{
                $txtS = $window.FindName("txtStatus")
                $txtS.Text       = $Msg
                $txtS.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
            })
        }

        function Send-KnockPacket {
            param([string]$Target, [int]$Port)
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($Target, $Port, $null, $null)
                $ar.AsyncWaitHandle.WaitOne(1500, $false) | Out-Null
                $tcp.Close()
            } catch {}
        }

        try {
            Set-UIStatus "Knocking..." "#0ea5e9"

            for ($i = 0; $i -lt $knockPorts.Count; $i++) {
                $port = $knockPorts[$i]
                $step = $i + 1
                Set-UIStatus "[$step/$($knockPorts.Count)] Knocking port $port ..." "#0ea5e9"
                Send-KnockPacket -Target $hostname -Port $port
                Start-Sleep -Milliseconds 300
            }

            Set-UIStatus "Knock complete. Launching SSH..." "#22c55e"
            Start-Sleep -Milliseconds 400

            # Try native OpenSSH first (ships with Windows 10 1803+), fall back to PuTTY
            $sshExe = Get-Command ssh.exe -ErrorAction SilentlyContinue
            if ($sshExe) {
                Start-Process "ssh.exe" -ArgumentList "-p $sshPort $user@$hostname"
                Set-UIStatus "SSH session launched (OpenSSH)." "#22c55e"
            } else {
                $putty = Get-Command putty.exe -ErrorAction SilentlyContinue
                if ($putty) {
                    Start-Process "putty.exe" -ArgumentList "-P $sshPort $user@$hostname"
                    Set-UIStatus "SSH session launched (PuTTY)." "#22c55e"
                } else {
                    Set-UIStatus "Error: No SSH client found. Install OpenSSH or PuTTY." "#ef4444"
                }
            }
        } catch {
            Set-UIStatus "Error: $($_.Exception.Message)" "#ef4444"
        } finally {
            $window.Dispatcher.Invoke([Action]{
                $btnKnock.IsEnabled = $true
            })
        }
    }) | Out-Null

    $ps.BeginInvoke() | Out-Null
})

# Handle window close to clean up
$window.Add_Closed({ [Environment]::Exit(0) })

$window.ShowDialog() | Out-Null
