@echo off

echo building project
zig build --verbose --prominent-compile-errors -Doptimize=Debug