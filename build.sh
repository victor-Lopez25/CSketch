#!/bin/bash
sdllibpath=path/to/sdl/lib/x64/
sdlincludepath=path/to/sdl/include/
out=pixel_sketch.exe
cpath=../src
csrc=$cpath/main.c

if [! -d bin] then
  mkdir bin
fi

cd bin
gcc %csrc% -o%out% -Wall -Wextra -I%sdlincludepath% -L%sdllibpath% -l SDL3
cd ..