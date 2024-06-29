@echo off

set out=csketch.exe
set sdllibpath=C:\SDL2-2.26.1\lib\x64\
set sdlincludepath=C:\SDL2-2.26.1\include\
set defines=-D_CRT_SECURE_NO_WARNINGS
set opts=-GR- -EHa- -nologo -Zi -W4
set code=%cd%\src

copy dependencies\sdl2.dll bin\sdl2.dll /Y > NUL

pushd bin
cl %defines% %opts% %code%\main.cpp -Fe%out% -I%sdlincludepath% /link /libpath:%sdllibpath% SDL2.lib -incremental:no
::%out% drawing.bmp

popd