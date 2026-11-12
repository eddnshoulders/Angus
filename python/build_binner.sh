#!/usr/bin/env bash
set -euo pipefail

gcc -O3 -fPIC -shared -o libangus_binner.so angus_binner.c
echo "built $(pwd)/libangus_binner.so"
