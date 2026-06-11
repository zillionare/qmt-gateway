@echo off
:: Wrapper invoked by the QMTGateway Windows service (nssm). Do not run
:: directly. start.bat is the manual / debug launcher; this file is the
:: service's AppPath because going through a .bat wrapper is the most
:: reliable way to deliver a multi-line environment block to the embedded
:: python - nssm 2.24's AppEnvironmentExtra has quoting / encoding
:: issues under PowerShell 5.1 and on CJK install paths, so we set each
;; variable here with cmd's set syntax (#66).

setlocal
cd /d "%~dp0"

set "QMT_GATEWAY_HOME=%~dp0data\home"
set "PYTHONUTF8=1"
set "PYTHONPATH=%~dp0app;%~dp0python\Lib\site-packages"
set "PATH=%~dp0python;%PATH%"

python\python.exe -m qmt_gateway
endlocal
