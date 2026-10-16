# Simple lossless JPEG XL

This is a simple standalone lossless JPEG XL encoder, based on libjxl effort 1 (`cjxl -d 0 -e 1`) but with all the handwritten SIMD removed.

It is a single C++ file without any dependencies (besides the standard library).
The command line tool takes a PPM file (or PAM, to allow for alpha) as input, and produces a JPEG XL file as output.
