#!/bin/sh

para=$#;

if [ $para != 1 ]; then
    echo "we just need one parameter, line or local";
    exit 1;
fi

place=$1;

if [ $place == "local" ]; then
    sed '3s/\(url:\ http:\/\/\).*/\1localhost:4000/g' _config.yml >> _config.yml.tt
    mv _config.yml.tt _config.yml
elif [ $place == "line" ]; then
    sed '3s/\(url:\ http:\/\/\).*/\1baotiao.github.io/g' _config.yml >> _config.yml.tt
    mv _config.yml.tt _config.yml;
else
    echo "we just need line or local";
    exit 2;
fi
jekyll server
