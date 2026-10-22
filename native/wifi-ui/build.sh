#!/bin/sh
set -eu
exec sh "$(dirname -- "$0")/build-native.sh"
