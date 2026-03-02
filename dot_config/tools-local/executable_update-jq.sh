#!/usr/bin/env bash

set -euo pipefail

JQ_SRC="$HOME/src/jq"
JQ_INSTALL_PREFIX="$HOME/.local"

if [[ -d $JQ_SRC ]]; then
    cd $JQ_SRC
    VERSION=$(git describe --tags)
    VERSION_CLEAN="${VERSION#v}"
    git pull
    git submodule update --init
    echo "Building jq $VERSION_CLEAN..."
    autoreconf -i
    ./configure --with-oniguruma=builtin --prefix=/home/craig/.local
    make clean
    make -j8
    make check
    make install PREFIX=~/.local
    echo "Installed jq $VERSION_CLEAN to $JQ_INSTALL_PREFIX/bin"

else
    echo "$JQ_SRC does not exist.  Exiting."
    exit 1
fi

exit 0
