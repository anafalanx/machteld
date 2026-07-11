@echo off
setlocal
pushd "%~dp0"

C:\dev\z.exe gcc -std=c23 -Os -s -municode -DUNICODE -D_UNICODE -Wall -Wextra -Werror -Wl,--no-insert-timestamp process_fixture.c -o process_fixture.exe
set "build_status=%ERRORLEVEL%"

popd
exit /b %build_status%
