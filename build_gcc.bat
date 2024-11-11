@echo off

:: Find SDL3 here:
:: https://github.com/libsdl-org/SDL/releases/tag/preview-3.1.6
set sdllibpath=D:\SDL3-3.1.6\lib\x64\
set sdlincludepath=D:\SDL3-3.1.6\include\
set out=pixel_sketch.exe
set cpath=..\src
set csrc=%cpath%\main.c

if not exist bin mkdir bin

pushd bin
gcc %csrc% -o%out% -Wall -Wextra -I%sdlincludepath% -L%sdllibpath% -l SDL3
popd
