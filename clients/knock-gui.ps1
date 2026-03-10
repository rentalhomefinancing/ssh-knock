# SSH Knock - Port Knocking GUI Client
# Placeholders replaced during server install:
#   __KNOCK1__, __KNOCK2__, __KNOCK3__ - knock sequence ports
#   __SSH_PORT__ - actual SSH port after knock
#   __HOSTNAME__ - server hostname/IP

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --- Placeholder guard -----------------------------------------------------------
$knockPorts = @(__KNOCK1__, __KNOCK2__, __KNOCK3__)
$sshPort    = __SSH_PORT__
$defaultHost = "__HOSTNAME__"

# Detect unreplaced placeholders (they will cause a parse error above, but if
# someone wraps them in quotes to test the GUI, catch it here).
foreach ($p in $knockPorts) {
    if ($p -is [string] -and $p -match '__KNOCK\d__') {
        [System.Windows.MessageBox]::Show(
            "Knock ports have not been configured.`nPlaceholders __KNOCK1/2/3__ must be replaced during install.",
            "SSH Knock - Configuration Error",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
        return
    }
}
if ($sshPort -is [string] -and $sshPort -match '__SSH_PORT__') {
    [System.Windows.MessageBox]::Show(
        "SSH port has not been configured.`nPlaceholder __SSH_PORT__ must be replaced during install.",
        "SSH Knock - Configuration Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error) | Out-Null
    return
}
if ($defaultHost -match '__HOSTNAME__') {
    $defaultHost = ""
}

# --- Script-scoped state ---------------------------------------------------------
$script:knockRunning = $false
$script:currentRunspace = $null
$script:currentPowerShell = $null
$script:currentAsyncResult = $null

# --- XAML ------------------------------------------------------------------------
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SSH Knock"
    Width="420" Height="420"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Background="#0f172a">

    <Window.Resources>
        <Style x:Key="LabelStyle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#94a3b8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
        </Style>
    </Window.Resources>

    <Grid Margin="24,20,24,20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
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
                <Border CornerRadius="4" BorderBrush="#475569" BorderThickness="1" Margin="0,0,0,10">
                    <TextBox Name="txtHost" MaxLength="253"
                             Background="#334155" Foreground="#f1f5f9"
                             BorderThickness="0" Padding="8,6" FontSize="14"
                             CaretBrush="#f1f5f9"/>
                </Border>

                <TextBlock Text="SSH User" Style="{StaticResource LabelStyle}"/>
                <Border CornerRadius="4" BorderBrush="#475569" BorderThickness="1">
                    <TextBox Name="txtUser" Text="root" MaxLength="64"
                             Background="#334155" Foreground="#f1f5f9"
                             BorderThickness="0" Padding="8,6" FontSize="14"
                             CaretBrush="#f1f5f9"/>
                </Border>
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
            <TextBlock Text="Knock and Connect" FontSize="15" FontWeight="Bold" VerticalAlignment="Center"/>
        </Button>

        <!-- Progress bar -->
        <Border Grid.Row="3" Margin="0,0,0,10" CornerRadius="3" Background="#334155" Height="6"
                ClipToBounds="True">
            <Border Name="progressBar" Background="#0ea5e9" CornerRadius="3"
                    HorizontalAlignment="Left" Width="0"/>
        </Border>

        <!-- Status -->
        <Border Grid.Row="4" Background="#1e293b" CornerRadius="6" Padding="12,10" Margin="0,0,0,14" MinHeight="60">
            <TextBlock Name="txtStatus" Text="Ready." Foreground="#94a3b8" FontSize="12"
                       TextWrapping="Wrap" FontFamily="Consolas"/>
        </Border>

        <!-- Spacer -->
        <Grid Grid.Row="5"/>

        <!-- Knock sequence info -->
        <Border Grid.Row="6" Background="#1e293b" CornerRadius="6" Padding="10,8">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <TextBlock Text="Sequence: " Foreground="#64748b" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Name="txtSequence" Foreground="#0ea5e9" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Text=" -> SSH " Foreground="#64748b" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
                <TextBlock Name="txtSshPort" Foreground="#22c55e" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$txtHost      = $window.FindName("txtHost")
$txtUser      = $window.FindName("txtUser")
$btnKnock     = $window.FindName("btnKnock")
$txtStatus    = $window.FindName("txtStatus")
$txtSequence  = $window.FindName("txtSequence")
$txtSshPort   = $window.FindName("txtSshPort")
$progressBar  = $window.FindName("progressBar")

$txtHost.Text     = $defaultHost
$txtSequence.Text = ($knockPorts -join " > ")
$txtSshPort.Text  = "$sshPort"

# --- Helper: update status via Dispatcher (non-blocking) -------------------------
function Set-Status {
    param([string]$Message, [string]$Color = "#94a3b8")
    $window.Dispatcher.BeginInvoke([Action]{
        $txtStatus.Text       = $Message
        $txtStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    }.GetNewClosure())
}

# --- Helper: update progress bar via Dispatcher ----------------------------------
function Set-Progress {
    param([double]$Fraction)  # 0.0 to 1.0
    $window.Dispatcher.BeginInvoke([Action]{
        $maxWidth = $progressBar.Parent.ActualWidth
        if ($maxWidth -le 0) { $maxWidth = 372 }
        $progressBar.Width = [Math]::Max(0, [Math]::Min($maxWidth, $maxWidth * $Fraction))
    }.GetNewClosure())
}

# --- Helper: dispose previous runspace cleanly -----------------------------------
function Dispose-PreviousRunspace {
    if ($script:currentPowerShell -ne $null) {
        try {
            if ($script:currentAsyncResult -ne $null) {
                $script:currentPowerShell.EndInvoke($script:currentAsyncResult) | Out-Null
            }
        } catch { }
        try { $script:currentPowerShell.Dispose() } catch { }
        $script:currentPowerShell = $null
        $script:currentAsyncResult = $null
    }
    if ($script:currentRunspace -ne $null) {
        try { $script:currentRunspace.Close() } catch { }
        try { $script:currentRunspace.Dispose() } catch { }
        $script:currentRunspace = $null
    }
}

# --- Input validation regex ------------------------------------------------------
$validInputPattern = '^[a-zA-Z0-9._\-]+$'

# --- Knock handler ---------------------------------------------------------------
$knockAction = {
    # Double-click protection
    if ($script:knockRunning) { return }

    $hostname = $txtHost.Text.Trim()
    $user     = $txtUser.Text.Trim()

    # Validate hostname
    if ([string]::IsNullOrEmpty($hostname)) {
        Set-Status "Error: Hostname is required." "#ef4444"
        return
    }
    if ($hostname -notmatch $validInputPattern) {
        Set-Status "Error: Hostname contains invalid characters." "#ef4444"
        return
    }

    # Validate username
    if ([string]::IsNullOrEmpty($user)) {
        Set-Status "Error: SSH user is required." "#ef4444"
        return
    }
    if ($user -notmatch $validInputPattern) {
        Set-Status "Error: Username contains invalid characters." "#ef4444"
        return
    }

    # DNS pre-validation
    Set-Status "Resolving $hostname ..." "#0ea5e9"
    Set-Progress 0.0
    try {
        [System.Net.Dns]::GetHostEntry($hostname) | Out-Null
    } catch {
        Set-Status "Error: Cannot resolve hostname '$hostname'. Check DNS or use an IP." "#ef4444"
        Set-Progress 0.0
        return
    }

    $script:knockRunning = $true
    $btnKnock.IsEnabled = $false

    # Dispose any previous runspace before creating a new one
    Dispose-PreviousRunspace

    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("window",     $window)
    $runspace.SessionStateProxy.SetVariable("knockPorts", $knockPorts)
    $runspace.SessionStateProxy.SetVariable("sshPort",    $sshPort)
    $runspace.SessionStateProxy.SetVariable("hostname",   $hostname)
    $runspace.SessionStateProxy.SetVariable("user",       $user)
    $runspace.SessionStateProxy.SetVariable("btnKnock",   $btnKnock)
    $runspace.SessionStateProxy.SetVariable("progressBar",$progressBar)

    $script:currentRunspace = $runspace

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    $ps.AddScript({
        function Set-UIStatus {
            param([string]$Msg, [string]$Color = "#94a3b8")
            $window.Dispatcher.BeginInvoke([Action]{
                $txtS = $window.FindName("txtStatus")
                $txtS.Text       = $Msg
                $txtS.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
            }.GetNewClosure())
        }

        function Set-UIProgress {
            param([double]$Fraction)
            $window.Dispatcher.BeginInvoke([Action]{
                $maxWidth = $progressBar.Parent.ActualWidth
                if ($maxWidth -le 0) { $maxWidth = 372 }
                $progressBar.Width = [Math]::Max(0, [Math]::Min($maxWidth, $maxWidth * $Fraction))
            }.GetNewClosure())
        }

        function Send-KnockPacket {
            param([string]$TargetHost, [int]$Port)
            $tcp = $null
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $ar  = $tcp.BeginConnect($TargetHost, $Port, $null, $null)
                $ar.AsyncWaitHandle.WaitOne(1500, $false) | Out-Null
            } catch {
                # Expected - knock ports typically reject/drop connections.
                # The SYN packet is what matters.
            } finally {
                if ($tcp -ne $null) {
                    try { $tcp.Close() } catch { }
                    try { $tcp.Dispose() } catch { }
                }
            }
        }

        try {
            $totalSteps = $knockPorts.Count + 1  # knocks + SSH launch
            Set-UIStatus "Knocking..." "#0ea5e9"

            for ($i = 0; $i -lt $knockPorts.Count; $i++) {
                $port = $knockPorts[$i]
                $step = $i + 1
                Set-UIStatus "Knock $step/$($knockPorts.Count) - port $port ..." "#0ea5e9"
                Set-UIProgress (($step - 0.5) / $totalSteps)
                Send-KnockPacket -TargetHost $hostname -Port $port
                Start-Sleep -Milliseconds 300
                Set-UIProgress ($step / $totalSteps)
            }

            Set-UIStatus "Knock complete. Launching SSH..." "#22c55e"
            Set-UIProgress (($knockPorts.Count + 0.5) / $totalSteps)
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
            Set-UIProgress 1.0
        } catch {
            Set-UIStatus "Error: $($_.Exception.Message)" "#ef4444"
            Set-UIProgress 0.0
        } finally {
            $window.Dispatcher.BeginInvoke([Action]{
                $btnKnock.IsEnabled = $true
            })
        }
    }) | Out-Null

    $script:currentPowerShell = $ps
    $script:currentAsyncResult = $ps.BeginInvoke()

    # Register completion callback to clean up and release the running flag
    Register-ObjectEvent -InputObject $script:currentAsyncResult.AsyncWaitHandle -EventName 'WaitCallbackEvent' -Action {
        # This event doesn't fire reliably; cleanup happens in Dispose-PreviousRunspace
        # and window Closed handler. The knockRunning flag is released below via polling.
    } -ErrorAction SilentlyContinue | Out-Null

    # Use a DispatcherTimer to poll for completion and reset the flag
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if ($script:currentAsyncResult -ne $null -and $script:currentAsyncResult.IsCompleted) {
            $script:knockRunning = $false
            $this.Stop()
        }
    }.GetNewClosure())
    $timer.Start()
}

# --- Button click -----------------------------------------------------------------
$btnKnock.Add_Click($knockAction)

# --- Key bindings: Enter to knock, Escape to close -------------------------------
$window.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        $knockAction.Invoke()
        $e.Handled = $true
    }
    elseif ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $window.Close()
        $e.Handled = $true
    }
})

# --- Focus hostname on load -------------------------------------------------------
$window.Add_ContentRendered({
    $txtHost.Focus() | Out-Null
    if ($txtHost.Text.Length -gt 0) {
        $txtHost.SelectAll()
    }
})

# --- Focus highlight for TextBoxes ------------------------------------------------
foreach ($tb in @($txtHost, $txtUser)) {
    $tb.Add_GotFocus({
        $this.Parent.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString("#0ea5e9")
    })
    $tb.Add_LostFocus({
        $this.Parent.BorderBrush = [Windows.Media.BrushConverter]::new().ConvertFromString("#475569")
    })
}

# --- Clean up on window close (no Environment.Exit) -------------------------------
$window.Add_Closed({
    $script:knockRunning = $false
    Dispose-PreviousRunspace
})

$window.ShowDialog() | Out-Null
