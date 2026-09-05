#!/bin/sh
set -eu

required_file() {
  if [ ! -s "$1" ]; then
    echo "Required Postfix file is missing or empty: $1" >&2
    exit 1
  fi
}

required_file /etc/postfix/main.cf
required_file /etc/postfix/recipient-map/virtual

exec postfix start-fg
