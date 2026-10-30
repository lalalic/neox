#!/bin/sh
set -eu
helper="$1"
test "$("$helper" version)" = 1
"$helper" list | grep -qx 'dns.flush'
"$helper" check dns.flush | grep -qx '/usr/bin/dscacheutil -flushcache'
"$helper" check vpn.server.restart | grep -qx '/bin/launchctl kickstart -k system/io.macikev2.server'
for action in '/bin/sh' 'dns.flush;id' '../dns.flush' 'sudo' ''; do
  if "$helper" check "$action" >/dev/null 2>&1; then echo "unexpected allow $action" >&2; exit 1; fi
done
if "$helper" run dns.flush extra >/dev/null 2>&1; then exit 1; fi
if [ "$(id -u)" != 0 ]; then
  if "$helper" run dns.flush >/dev/null 2>&1; then echo 'executed unprivileged!' >&2; exit 1; fi
fi
echo 'privileged helper fail-closed tests passed'
