; QMT Gateway Windows Installer (NSIS)
; Issue #48: NSIS installer with embedded Python
;
; Prerequisites:
;   - NSIS 3.x installed (makensis in PATH) - see installer/README.md
;   - Python 3.11+ on PATH (used to generate installer\requirements.txt)
;   - Python 3.13 embeddable package downloaded to installer\python-embed.zip
;
; Build: makensis /INPUTCHARSET UTF8 installer\installer.nsi

Unicode True
SetCompress off
!define PRODUCT_NAME "匡醍 QMT 交易网关"
!define PRODUCT_VERSION "0.1.0"
!define BUILD_NUMBER "0"  ; Replaced by CI with github.run_number
!define PRODUCT_PUBLISHER "zillionare"
!define PRODUCT_WEB_SITE "https://github.com/zillionare/qmt-gateway"
!define PRODUCT_DIR_REGKEY "Software\Microsoft\Windows\CurrentVersion\App Paths\qmt-gateway.exe"
!define PRODUCT_DIR_REGKEY_WOW "Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\qmt-gateway.exe"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
!define PRODUCT_UNINST_ROOT_KEY "HKLM"
!define PRODUCT_STARTMENU_REGVAL "NSIS:StartMenuDir"
!define PRODUCT_INSTALL_STATE_KEY "Software\qmt-gateway"
!define INSTALLER_SCRIPT_NAME "qmt-gateway-install-python.ps1"
!define INSTALLER_SCRIPT_PATH "$INSTDIR\${INSTALLER_SCRIPT_NAME}"
!define PIP_INDEX_URL "https://pypi.tuna.tsinghua.edu.cn/simple"
!define PIP_TRUSTED_HOST "pypi.tuna.tsinghua.edu.cn"
!define INSTALL_LOG_NAME "install.log"
!define REQUIREMENTS_NAME "requirements.txt"
!define REQUIREMENTS_PATH "${__FILEDIR__}\${REQUIREMENTS_NAME}"

; #67 / #68 / #74: build-time preprocessor steps.
;   - generate-requirements.py writes installer\requirements.txt from pyproject.toml.
;   - generate-bitmaps.ps1 converts quantide.png / contact-us.png to the BMP
;     format that MUI2 requires for MUI_WELCOMEFINISHPAGE_BITMAP and produces
;     quantide.ico for MUI_ICON / MUI_UNICON.
;   - download-nssm.ps1 caches nssm.exe under installer\ so the Core section
;     can ship it. nssm wraps the embedded python as a Windows service so the
;     gateway runs at boot, restarts on crash, and writes its own logs (#66).
!system 'python ".\generate-requirements.py" "..\pyproject.toml" ".\requirements.txt"' = 0
!system 'powershell -NoProfile -ExecutionPolicy Bypass -File ".\generate-bitmaps.ps1"' = 0
!system 'powershell -NoProfile -ExecutionPolicy Bypass -File ".\download-nssm.ps1"' = 0

; The NSIS built-in zip plugin is not part of the default choco NSIS 3.x
; install, so we do not rely on it. python-embed.zip is extracted with the
; built-in Windows tar.exe below.

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"


!macro LogInit
    FileOpen $0 "$INSTDIR\${INSTALL_LOG_NAME}" w
    FileClose $0
!macroend


!macro LogLine TEXT
    FileOpen $0 "$INSTDIR\${INSTALL_LOG_NAME}" a
    FileWrite $0 "${TEXT}$\r$\n"
    FileClose $0
!macroend


!macro LogStep LABEL
    Push $0
    Push $1
    FileOpen $0 "$INSTDIR\${INSTALL_LOG_NAME}" a
    FileWrite $0 "==== ${LABEL} ====$\r$\n"
    FileClose $0
    Pop $1
    Pop $0
!macroend


!macro AbortOnExecFailure LABEL
    Pop $1
    ${If} $1 != "0"
        !insertmacro LogLine "ERROR: ${LABEL} failed with exit code $1"
        Abort "${LABEL} failed"
    ${EndIf}
!macroend

; MUI Settings
!define MUI_ABORTWARNING
; #71: the user explicitly asked to drop the quantide brand logo from the
; title bar, taskbar, and wizard header. quantide.png is a square stamp that
; turns into a blurry red rectangle when stretched into the installer's
; icon/header slots, so we let NSIS use its default icon everywhere. The
; welcome page still shows contact-us.bmp (the QR) on the left and the
; install/finish pages use the standard NSIS art.
;
; #67 / #72: the welcome page and the finish page share a 109x193 left-side
; bitmap slot, drawn from MUI_WELCOMEFINISHPAGE_BITMAP. This is the official
; MUI2 macro name; MUI_WELCOMEPAGE_BITMAP does not exist. MUI loads the
; bitmap into $PLUGINSDIR\modern-wizard.bmp via File /oname and the welcome
; /finish page callbacks bind it to NSD_CreateBitmap 0u 0u 109u 193u.
; We render contact-us.bmp (180x180) and let MUI draw it scaled into the
; 109x193 slot.
!define MUI_WELCOMEFINISHPAGE_BITMAP "contact-us.bmp"

; MUI_LANGUAGE is intentionally placed AFTER all !insertmacro MUI_PAGE_*
; so that the finish page's left-side bitmap GUIInit callback
; (mui.FinishPage.GUIInit) is registered before .onGUIInit is generated
; (MUI2 inserts .onGUIInit when the first MUI_LANGUAGE expands). The
; section description LangStrings below are looked up at runtime, but
; NSIS resolves ${LANG_SIMPCHINESE} at compile time, so we pre-define it
; here so the lookup is stable before MUI_LANGUAGE is expanded.
!define LANG_SIMPCHINESE "2052"

; MUI2 standard page titles + subtitles. Each LangString id is read by
; Section descriptions MUST be LangStrings that are looked up at runtime via
; MUI_DESCRIPTION_TEXT - they have to be registered before any
; !insertmacro MUI_PAGE_COMPONENTS, otherwise MUI_DESCRIPTION_TEXT expands
; the language id to a numeric code and the component selection page
; shows mojibake instead of the description (#51).
;
; #66: SEC_AUTOSTART is removed. Auto-start at boot is now provided by the
; Windows service installed in SEC_CORE via nssm; users no longer need to
; opt in, and the previous logon-time scheduled task / start-silent.vbs
; flow is gone.
LangString DESC_SEC_CORE ${LANG_SIMPCHINESE} "核心组件（必须安装，将作为 Windows 服务后台运行并开机自启）"
LangString DESC_SEC_FIREWALL ${LANG_SIMPCHINESE} "防火墙入站规则（允许局域网访问）"

; Failure dialog
LangString INSTALL_FAILED_LOG_MESSAGE ${LANG_SIMPCHINESE} \
    "安装失败。请查看安装目录下的 ${INSTALL_LOG_NAME}。如果尚未选择安装目录，请截屏反馈。"

; Welcome page - MUI2 reads MUI_TEXT_WELCOME_INFO_TITLE/TEXT defined above.
!insertmacro MUI_PAGE_WELCOME

; License page
; !insertmacro MUI_PAGE_LICENSE "LICENSE"

; Directory page
!insertmacro MUI_PAGE_DIRECTORY

; Components / Options page
!define MUI_COMPONENTSPAGE_SMALLDESC
!insertmacro MUI_PAGE_COMPONENTS

; Start menu page
var ICONS_GROUP
!define MUI_STARTMENUPAGE_DEFAULTFOLDER "${PRODUCT_NAME}"
!define MUI_STARTMENUPAGE_REGISTRY_ROOT "${PRODUCT_UNINST_ROOT_KEY}"
!define MUI_STARTMENUPAGE_REGISTRY_KEY "${PRODUCT_UNINST_KEY}"
!define MUI_STARTMENUPAGE_REGISTRY_VALUENAME "${PRODUCT_STARTMENU_REGVAL}"
!insertmacro MUI_PAGE_STARTMENU Application $ICONS_GROUP

; Instfiles page
!insertmacro MUI_PAGE_INSTFILES

; Finish page - MUI2 reads MUI_TEXT_FINISH_INFO_TITLE/TEXT defined above.
;
; #66: the gateway is installed as a Windows service that starts at the end
; of SEC_CORE, so the "run now" checkbox is intentionally removed. The
; "view install log" checkbox is kept (unchecked) as a diagnostic shortcut.
; The browser is opened automatically by Section -Post once the service is
; reachable on http://localhost:8130, so the user does not have to click
; anything to see the gateway UI.
!define MUI_FINISHPAGE_SHOWREADME_TEXT "查看安装日志"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\${INSTALL_LOG_NAME}"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_INSTFILES

; IMPORTANT: !insertmacro MUI_LANGUAGE must come AFTER every !insertmacro
; MUI_PAGE_* / !insertmacro MUI_UNPAGE_*. MUI2 inserts .onGUIInit (and
; therefore the install-time call to mui.FinishPage.GUIInit) when the
; first MUI_LANGUAGE is expanded. If MUI_LANGUAGE runs before
; MUI_PAGE_FINISH, mui.FinishPage.GUIInit has not been registered yet and
; NSIS prunes it as dead code (warning 6010), leaving the welcome/finish
; left-side bitmap slot empty (#73).
!insertmacro MUI_LANGUAGE "SimpChinese"

; MUI2's standard page titles and subtitles are preprocessor !defines (see
; MUI_DEFAULT in Interface.nsh), not LangStrings. Override them AFTER
; !insertmacro MUI_LANGUAGE so they survive until each page callback sends
; them to the header / subtitle static controls via SendMessage WM_SETTEXT.
; Without these overrides the headers collapse to a single button-high
; strip with no subtitle row (#72).
!define MUI_TEXT_WELCOME_INFO_TITLE "请先安装 QMT 交易客户端"
!define MUI_TEXT_WELCOME_INFO_SUBTITLE "请先确认本机已经安装迅投 QMT 交易客户端，然后继续。"
!define MUI_TEXT_WELCOME_INFO_TEXT \
    "本软件需要配置迅投 QMT 交易客户端使用。在安装本软件之前，就需要安装好 QMT。请联系您的券商客服，获取 QMT 软件的下载方式。$\n$\n\
     如果需要帮助，请扫描左侧二维码联系我们。"

!define MUI_TEXT_DIRECTORY_TITLE "选择安装位置"
!define MUI_TEXT_DIRECTORY_SUBTITLE "请选择 $(^NameDA) 的安装文件夹"

!define MUI_TEXT_COMPONENTS_TITLE "选择安装组件"
!define MUI_TEXT_COMPONENTS_SUBTITLE "请勾选需要安装的可选组件"

!define MUI_TEXT_STARTMENU_TITLE "选择开始菜单文件夹"
!define MUI_TEXT_STARTMENU_SUBTITLE "请选择开始菜单中的文件夹"

!define MUI_TEXT_INSTFILES_TITLE "正在安装"
!define MUI_TEXT_INSTFILES_SUBTITLE "请稍候，正在完成 $(^NameDA) 的安装"

!define MUI_TEXT_FINISH_INFO_TITLE "$(^Name) 安装程序结束"
!define MUI_TEXT_FINISH_INFO_TEXT \
    "$(^Name) 已经成功安装到本机。$\r$\n点击『完成(F)』关闭安装程序。"

; MUI reserve files
; MUI_RESERVEFILE_INSTALLOPTIONS is not supported in MUI2
; !insertmacro MUI_RESERVEFILE_INSTALLOPTIONS

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "QMT-Gateway-Setup-${PRODUCT_VERSION}-build${BUILD_NUMBER}.exe"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
ShowInstDetails show
ShowUnInstDetails show
RequestExecutionLevel admin

Function .onInit
    ; Chinese-only installer. The single registered language table above is
    ; used directly; NSIS will not pop a language picker because no picker
    ; macro is invoked here.
FunctionEnd

Function .onInstFailed
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(INSTALL_FAILED_LOG_MESSAGE)"
FunctionEnd

; Components - use English section names (NSIS limitation), descriptions are localized
Section "-Core" SEC_CORE
    SectionIn RO
    SetOverwrite on
    SetOutPath "$INSTDIR"

    CreateDirectory "$INSTDIR"
    SetOutPath "$INSTDIR"
    File /oname=${INSTALLER_SCRIPT_NAME} "install-python.ps1"
    !insertmacro LogInit
    !insertmacro LogStep "Core: create install dir"
    !insertmacro LogStep "Core: write uninstall registry"
    ; Publish InstallLocation immediately so PowerShell child processes can
    ; recover the install path from the registry without going through NSIS
    ; string expansion (which corrupts CJK under the system ANSI code page).
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "InstallLocation" "$INSTDIR"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_INSTALL_STATE_KEY}" "InstallLocation" "$INSTDIR"
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${INSTALLER_SCRIPT_PATH}" -Stage InitLogs'
    !insertmacro AbortOnExecFailure "Initialize install logs"
    !insertmacro LogStep "Core: create directories"

    ; Create directories
    CreateDirectory "$INSTDIR\python"
    CreateDirectory "$INSTDIR\app"
    CreateDirectory "$INSTDIR\data"

    !insertmacro LogStep "Core: copy embedded Python"
    ; Copy embedded Python distribution
    DetailPrint "正在释放内嵌 Python 3.13..."
    SetOutPath "$INSTDIR\python"
    File "python-embed.zip"

    !insertmacro LogStep "Core: extract embedded Python"
    ; Extract python-embed.zip via the built-in Windows tar.exe (ships with
    ; Windows 10 1803+ and Server 2019+, present on every supported system).
    ; tar -xf supports zip archives and handles Unicode paths reliably,
    ; unlike PowerShell 5.1's Expand-Archive which intermittently fails with
    ; 'Cannot access path' under CJK install paths.
    SetOutPath "$INSTDIR\python"
    nsExec::ExecToLog 'cmd.exe /c tar -xf "$INSTDIR\python\python-embed.zip" -C "$INSTDIR\python"'
    !insertmacro AbortOnExecFailure "Extract embedded Python"
    Delete "$INSTDIR\python\python-embed.zip"
    !insertmacro LogStep "Core: post-process embedded Python"
    ; Hand control to the PowerShell helper only to patch python313._pth so
    ; the embedded interpreter can import pip and our application package.
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${INSTALLER_SCRIPT_PATH}" -Stage Runtime'
    !insertmacro AbortOnExecFailure "Post-process embedded Python"

    !insertmacro LogStep "Core: copy application source"
    ; Copy application source to $INSTDIR\app
        SetOutPath "$INSTDIR\app\qmt_gateway"
    File /r /x ".venv" /x "__pycache__" /x ".git" /x "data" /x "installer" \
         "..\qmt_gateway\*.*"
        SetOutPath "$INSTDIR\app"
        File "..\pyproject.toml"
        File "..\README.md"
        File "requirements.txt"
    SetOutPath "$INSTDIR"

    !insertmacro LogStep "Core: copy startup scripts"
    ; start.bat is retained as a manual / debug entry point that runs the
    ; gateway in a console window. start-service.bat is the wrapper the
    ; QMTGateway Windows service invokes: it sets the per-service
    ; environment (QMT_GATEWAY_HOME, PYTHONPATH, ...) and then runs the
    ; embedded python. nssm's AppEnvironmentExtra cannot reliably carry the
    ; multi-line block we need under PowerShell 5.1 quoting, so we go via
    ; this wrapper instead (#66).
    File "start.bat"
    File "start-service.bat"

    !insertmacro LogStep "Core: copy nssm.exe"
    ; nssm.exe wraps python.exe as a Windows service. The Core section ships
    ; it next to start.bat so install-service.ps1 (and the uninstaller) can
    ; locate it via the same registry-driven InstallLocation lookup used by
    ; install-python.ps1.
    File "nssm.exe"

    !insertmacro LogStep "Core: bootstrap pip"
    ; Embed Python does not ship with venv/pip. Bootstrap pip with get-pip.py and
    ; install dependencies into the embedded Python's site-packages directly.
    SetOutPath "$INSTDIR\python"
    File "get-pip.py"
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${INSTALLER_SCRIPT_PATH}" -Stage BootstrapPip'
    !insertmacro AbortOnExecFailure "Bootstrap pip"

    !insertmacro LogStep "Core: install dependencies"
    ; Install dependencies into the embedded Python's site-packages.
    DetailPrint "正在安装 Python 依赖 (使用国内镜像源)..."
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${INSTALLER_SCRIPT_PATH}" -Stage InstallDependencies'
    !insertmacro AbortOnExecFailure "Install Python dependencies"

    !insertmacro LogStep "Core: write shortcuts"
    ; Shortcuts - since the gateway runs as a service and the UI is just a
    ; web page on http://localhost:8130, shortcuts open the URL directly via
    ; the .url internet shortcut written in Section -Post / -AdditionalIcons.
    ; start.bat is kept for advanced/debug usage but is not exposed as a
    ; shortcut to avoid confusing users who would then run a second copy in
    ; a console.
    !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    CreateDirectory "$SMPROGRAMS\$ICONS_GROUP"
    !insertmacro MUI_STARTMENU_WRITE_END

    !insertmacro LogStep "Core: install windows service"
    ; Register and start the QMTGateway Windows service via nssm. The script
    ; reads InstallLocation from the registry (already written above) so
    ; PowerShell never has to handle CJK paths on the command line.
    DetailPrint "正在安装并启动 QMT Gateway 服务..."
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install-service.ps1" -Stage Install'
    !insertmacro AbortOnExecFailure "Install Windows service"

    !insertmacro LogStep "Core: done"
SectionEnd

Section "Firewall" SEC_FIREWALL
    !insertmacro LogStep "Firewall: add inbound rule"
    DetailPrint "正在添加防火墙入站规则..."
    nsExec::ExecToLog 'netsh advfirewall firewall add rule name="QMT Gateway" dir=in action=allow protocol=tcp localport=8130 profile=private enable=yes'
SectionEnd

; Section descriptions are defined earlier, before MUI_PAGE_COMPONENTS,
; so MUI_DESCRIPTION_TEXT can resolve the localized strings at compile time.
;
; #66: SEC_AUTOSTART no longer exists - auto-start is provided by the
; QMTGateway Windows service installed unconditionally in SEC_CORE.
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SEC_CORE} $(DESC_SEC_CORE)
    !insertmacro MUI_DESCRIPTION_TEXT ${SEC_FIREWALL} $(DESC_SEC_FIREWALL)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function OpenBrowser
    ExecShell "open" "http://localhost:8130"
FunctionEnd

; Wait until the QMTGateway service is reachable on http://localhost:8130,
; then open the default browser on the gateway UI. Called from the very end
; of Section -Post (which runs after every other section, including the
; firewall section that may need the port). We cap the wait at 30 s so an
; unhealthy service does not block the installer's finish page forever;
; if the wait times out, we still open the browser so the user can read the
; service's recent logs and see the failure reason directly.
Function WaitForServiceAndOpenBrowser
    DetailPrint "正在等待 QMT Gateway 服务就绪..."
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "for ($i=0;$i -lt 30;$i++) { try { $r=(Invoke-WebRequest -UseBasicParsing -Uri http://127.0.0.1:8130/ -TimeoutSec 2); if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { exit 0 } } catch { }; Start-Sleep -Seconds 1 }; exit 0"'
    Call OpenBrowser
FunctionEnd


Section -AdditionalIcons
    !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    WriteIniStr "$INSTDIR\${PRODUCT_NAME}.url" "InternetShortcut" "URL" "${PRODUCT_WEB_SITE}"
    CreateShortCut "$SMPROGRAMS\$ICONS_GROUP\Website.lnk" "$INSTDIR\${PRODUCT_NAME}.url"
    CreateShortCut "$SMPROGRAMS\$ICONS_GROUP\Uninstall.lnk" "$INSTDIR\uninstall.bat"
    !insertmacro MUI_STARTMENU_WRITE_END
SectionEnd

Section -Post
    WriteUninstaller "$INSTDIR\uninstall.exe"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayName" "$(^Name)"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "UninstallString" "$INSTDIR\uninstall.exe"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
    WriteRegStr ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"

    ; #66: once everything is on disk, wait for the service to come up and
    ; open the gateway UI in the user's default browser. Runs at the very
    ; end of -Post so it sees the firewall rule (if the user enabled it)
    ; and the service installation from SEC_CORE.
    Call WaitForServiceAndOpenBrowser
SectionEnd

; Uninstaller
Function un.onInit
    !insertmacro MUI_UNGETLANGUAGE
FunctionEnd

Section Uninstall
    ; Stop the QMTGateway Windows service. install-service.ps1 reads
    ; InstallLocation from the registry so we do not need to pass the
    ; install dir on the command line.
    DetailPrint "正在停止 QMT Gateway 服务..."
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\install-service.ps1" -Stage Uninstall'

    ; Best-effort fallback for legacy installs that pre-date the service:
    ; kill any stray python / qmt-gateway processes the service may have
    ; left behind during a non-graceful shutdown.
    DetailPrint "正在停止 qmt-gateway 进程..."
    nsExec::ExecToLog 'taskkill /F /IM "qmt-gateway.exe"'
    nsExec::ExecToLog 'taskkill /F /IM "python.exe" /FI "WINDOWTITLE eq QMT*"'

    ; Remove legacy scheduled task from releases that still shipped
    ; start-silent.vbs + onlogon task. Silent because newer installs do not
    ; have it.
    nsExec::ExecToLog 'schtasks /delete /tn "QMT Gateway" /f'

    ; Remove firewall rule
    DetailPrint "正在删除防火墙规则..."
    nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="QMT Gateway"'

    ; Remove shortcuts
    !insertmacro MUI_STARTMENU_GETFOLDER Application $ICONS_GROUP
    Delete "$SMPROGRAMS\$ICONS_GROUP\Website.lnk"
    Delete "$SMPROGRAMS\$ICONS_GROUP\Uninstall.lnk"
    RMDir "$SMPROGRAMS\$ICONS_GROUP"

    ; Ask about data directory
    MessageBox MB_YESNO|MB_ICONQUESTION \
        "是否删除数据目录？$\n$\n选择「否」将保留数据以便将来恢复。" \
        /SD IDNO IDYES DeleteData IDNO KeepData

    DeleteData:
        RMDir /r "$INSTDIR\data"
        RMDir /r "$APPDATA\qmt-gateway"
        DetailPrint "数据目录已删除"

    KeepData:
        DetailPrint "数据目录已保留"

    ; Remove install directory (everything except data/, which user chose above)
    RMDir /r "$INSTDIR\python"
    RMDir /r "$INSTDIR\.venv"
    RMDir /r "$INSTDIR\app"
    Delete "$INSTDIR\start.bat"
    Delete "$INSTDIR\start-service.bat"
    Delete "$INSTDIR\nssm.exe"
    Delete "$INSTDIR\install-service.ps1"
    Delete "$INSTDIR\uninstall.exe"
    Delete "$INSTDIR\${PRODUCT_NAME}.url"
    ; Clean any other top-level files (e.g. qmt_gateway sources installed at root)
    Delete "$INSTDIR\__init__.py"
    Delete "$INSTDIR\__main__.py"
    Delete "$INSTDIR\app.py"
    Delete "$INSTDIR\config.py"
    Delete "$INSTDIR\init_wizard.py"
    Delete "$INSTDIR\pyproject.toml"
    Delete "$INSTDIR\qmt_init_helpers.py"
    Delete "$INSTDIR\qmt_login_automation.py"
    Delete "$INSTDIR\qmt_restart_helper.py"
    Delete "$INSTDIR\README.md"
    Delete "$INSTDIR\runtime.py"
    Delete "$INSTDIR\trading.py"
    Delete "$INSTDIR\xtquant_probe.py"
    RMDir "$INSTDIR\apis"
    RMDir "$INSTDIR\core"
    RMDir "$INSTDIR\db"
    RMDir "$INSTDIR\services"
    RMDir "$INSTDIR\web"
    RMDir "$INSTDIR"

    ; Remove registry keys
    DeleteRegKey ${PRODUCT_UNINST_ROOT_KEY} "${PRODUCT_UNINST_KEY}"
    DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"
    DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY_WOW}"
    SetAutoClose true
SectionEnd