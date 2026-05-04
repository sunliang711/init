#!/bin/bash
git clone https://github.com/qiuzi/dns2socks && cd dns2socks

gcc -pthread -Wall -O2 -o DNS2SOCKS DNS2SOCKS.c
