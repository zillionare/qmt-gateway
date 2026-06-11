@echo off
:: Manual / debug launcher for qmt-gateway.
::
:: The released installer runs the gateway as a Windows service (QMTGateway)
:: so this script is no longer the normal start path. It is kept for two
:: reasons:
::   1. Advanced users / engineers who want to run the gateway in a console
::      window to read tracebacks live.
::   2. Recovery when the service is broken - they can `sc stop QMTGateway`
::      and run this script to confirm the underlying python is healthy.
::
:: This script must NOT be used while QMTGateway is also running: both
:: instances will try to bind :8130 and the second will fail.

cd /d "%~dp0"
set "QMT_GATEWAY_HOME=%~dp0data\home"
set "PYTHONUTF8=1"
set "PYTHONPATH=%~dp0app;%~dp0python\Lib\site-packages"
set "PATH=%~dp0python;%PATH%"
python\python.exe -m qmt_gateway
