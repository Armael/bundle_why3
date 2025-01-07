#!/usr/bin/env bash

set -euo pipefail

WHY3_COMMIT=ec97d9abc

mkdir build

##### Clone why3 to build/why3 and prepare it to be pinned

git clone "https://gitlab.inria.fr/why3/why3.git" build/why3

pushd build/why3
git checkout -d $WHY3_COMMIT
popd

# custom .opam file to build with --enable-relocation
rm -rf build/why3/opam
cp why3.opam build/why3/

##### Create an opam switch in build/_opam with why3 and our bundle_tool

pushd build
opam switch create -y . ocaml.4.14.1

# TODO: automatically install depexts
opam pin add -k path -y ./why3

opam pin add -k path -y ../bundle_tool
popd
