cmake_minimum_required(VERSION 3.18.1)
project("yuv_converter")

add_library(yuv_converter SHARED yuv_converter.c)
target_include_directories(yuv_converter PRIVATE .)
