#!/bin/bash
if (($# < 2));then
    echo "usage: $(basename $0) source prefix [sliceSize]" >& 2
    exit 1
fi

sliceSize=${3:-"80m"}
source=${1}
prefix=${2}

if ! ls $source >/dev/null 2>&1;then
    echo "\"$source\" does not exist!!" >& 2
    exit 1
fi
echo $sliceSize

tar -cjv $source | split -b $sliceSize - "${prefix}_"
