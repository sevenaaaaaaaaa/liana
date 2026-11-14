@echo off
REM Liana TSF 构建（在 Windows 机器上运行，需 VS Build Tools / Windows SDK）
REM
REM 前置：
REM   1. Rust: rustup target add x86_64-pc-windows-msvc
REM   2. VS Build Tools（cl.exe 在 x64 Native Tools Command Prompt 里）
REM   3. liana 源码仓库（本脚本假定位于 %USERPROFILE%\liana）
REM
REM 产物：build\liana_tsf.dll
REM
REM ⚠ 状态：TSF 集成仍在联调（组合文本上屏、候选窗、DllRegisterServer 注册表写入均为
REM   TODO，DLL 也还没有导出表），所以 regsvr32 注册这一步现在必然失败。
REM   本脚本只保证「能编出 DLL」，方便开发者继续补实现。

setlocal
set ROOT=%~dp0..\..
set HERE=%~dp0
REM build 目录要先建：后面 two 步都要往里写文件（以前 copy 排在 mkdir 之前，首次构建必失败）
if not exist "%HERE%build" mkdir "%HERE%build"

echo ==^> 1/3 Rust 静态库（x86_64-pc-windows-msvc，staticlib 免链接器）
REM 用 cargo rustc（rustc 本身没有 -p / --manifest-path 这些选项）
cargo rustc --release -p liana-ffi --target x86_64-pc-windows-msvc --crate-type staticlib ^
    --manifest-path "%ROOT%\Cargo.toml"
if errorlevel 1 goto :fail
REM msvc 目标直接产出 MSVC 命名的 liana_ffi.lib
copy /y "%ROOT%\target\x86_64-pc-windows-msvc\release\liana_ffi.lib" "%HERE%build\liana_ffi.lib" >nul
if errorlevel 1 goto :fail

echo ==^> 2/3 词典（base.ifd）
cargo run --quiet --release -p xtask --manifest-path "%ROOT%\Cargo.toml" -- ^
    dict build "%ROOT%\crates\dict\data\base-large.tsv" -o "%HERE%build\base.ifd"
if errorlevel 1 goto :fail

REM TSF 的 IID/CLSID 定义：Windows SDK 10.0.26100 起不再随附 msctf.lib，
REM 优先用旧版导入库；没有就从 msctf.idl 用 midl 生成 msctf_i.c 并编译成 .obj 一起链接。
set "TSF_IMPORTLIB=msctf.lib"
set "TSF_IDL=%WindowsSdkDir%Include\%WindowsSDKLibVersion%um\msctf.idl"
for /f "delims=" %%i in ('where /r "%ProgramFiles(x86)%\Windows Kits\10\Lib" msctf.lib 2^>nul') do if not defined TSF_OLD_LIB set "TSF_OLD_LIB=%%i"
if defined TSF_OLD_LIB set "TSF_IMPORTLIB=%TSF_OLD_LIB%"
if not defined TSF_OLD_LIB if exist "%TSF_IDL%" call :gen_tsf_iid
echo     TSF 接口定义来源: %TSF_IMPORTLIB%


echo ==^> 3/3 MSVC 编译 TSF DLL
cl /nologo /W4 /EHsc /O2 /LD /I"%ROOT%\crates\ffi\include" ^
    "%HERE%textservice.cpp" ^
    /Fe"%HERE%build\liana_tsf.dll" ^
    /link "%HERE%build\liana_ffi.lib" user32.lib advapi32.lib %TSF_IMPORTLIB%
if errorlevel 1 goto :fail

echo.
echo 完成：%HERE%build\liana_tsf.dll
echo.
echo 注意：这个 DLL 目前还不能注册成输入法——
echo   · textservice.cpp 的 DllRegisterServer 返回 E_NOTIMPL（CTF/TIP 注册表写入未实现）
echo   · 没有导出表（缺 .def / __declspec(dllexport)），regsvr32 找不到 DllRegisterServer
echo   想验证导出（应能看到 DllRegisterServer 等）：
echo       dumpbin /exports "%HERE%build\liana_tsf.dll"
echo   等这两项补完后，才轮到「管理员 regsvr32」以及语言栏里添加「松萝」。
exit /b 0

:gen_tsf_iid
if not exist "%HERE%build\tsf" mkdir "%HERE%build\tsf"
echo     从 SDK 的 msctf.idl 生成接口定义（SDK 不再附带 msctf.lib）
midl /nologo /env x64 /out "%HERE%build\tsf" /h "%HERE%build\tsf\msctf_i.h" /iid "%HERE%build\tsf\msctf_i.c" /proxy "%HERE%build\tsf\msctf_p.c" /dlldata "%HERE%build\tsf\dlldata.c" "%TSF_IDL%"
if errorlevel 1 goto :fail
cl /nologo /O2 /c /I"%WindowsSdkDir%Include\%WindowsSDKLibVersion%um" /I"%HERE%build\tsf" "%HERE%build\tsf\msctf_i.c" /Fo"%HERE%build\tsf\msctf_i.obj"
if errorlevel 1 goto :fail
set "TSF_IMPORTLIB=%HERE%build\tsf\msctf_i.obj"
exit /b 0

:fail
echo 构建失败，见上方输出
exit /b 1
