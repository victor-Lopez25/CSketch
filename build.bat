@echo off

set opts=-no-bounds-check -debug -vet -vet-using-param -vet-style

odin build %cd% %opts%
PixelSketch.exe