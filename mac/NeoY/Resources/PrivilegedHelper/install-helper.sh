#!/bin/sh
# Single-use root installer. This script must be invoked by the OS prompt,
# never through an agent-provided arbitrary command or an unattended sudo ALL.
set -eu
umask 077
if [ "$(id -u)" != 0 ] || [ "$#" -ne 2 ]; then
  echo "requires root with exactly <staged-binary> <console-user>" >&2
  exit 77
fi
source="$1"
target_user="$2"
case "$target_user" in
  *[!a-zA-Z0-9_.-]*|'') echo "invalid account" >&2; exit 64 ;;
esac
id "$target_user" >/dev/null 2>&1 || exit 67
test -f "$source" && test ! -L "$source" && test -x "$source" || exit 66
/usr/bin/codesign --verify --strict \
  -R '=anchor apple generic and certificate leaf[subject.OU] = "JABNLDLN8G"' "$source" || exit 65

helper_dir=/Library/PrivilegedHelperTools
helper="$helper_dir/com.neox.neoy.helper"
/usr/bin/install -d -o root -g wheel -m 0755 "$helper_dir"
/usr/bin/install -o root -g wheel -m 0755 "$source" "$helper.new"
/usr/bin/codesign --verify --strict \
  -R '=anchor apple generic and certificate leaf[subject.OU] = "JABNLDLN8G"' "$helper.new" || exit 65
# Roll back both binary and policy on any failed installation step.
policy="/private/etc/sudoers.d/neoy-privileged-helper"
helper_backup="$helper.previous"
policy_backup="$policy.previous"
helper_replaced=0
policy_replaced=0
/bin/rm -f "$helper_backup" "$policy_backup"
restore_on_error() {
  result=$?
  trap - EXIT
  if [ "$result" -ne 0 ]; then
    if [ "$helper_replaced" -eq 1 ]; then
      /bin/rm -f "$helper"
      if [ -f "$helper_backup" ]; then /bin/mv "$helper_backup" "$helper"; fi
    fi
    if [ "$policy_replaced" -eq 1 ]; then
      /bin/rm -f "$policy"
      if [ -f "$policy_backup" ]; then /bin/mv "$policy_backup" "$policy"; fi
    fi
    /bin/rm -f "$helper.new" "$policy.new"
  fi
  exit "$result"
}
trap restore_on_error EXIT
if [ -f "$helper" ]; then /bin/mv -f "$helper" "$helper_backup"; fi
helper_replaced=1
/bin/mv -f "$helper.new" "$helper"
/usr/sbin/chown root:wheel "$helper"
/bin/chmod 0755 "$helper"

# macOS sudoers.d must be included by /etc/sudoers; verify via visudo.
tmp="$policy.new"
printf '%s\n' "$target_user ALL=(root) NOPASSWD: $helper" > "$tmp"
/usr/sbin/chown root:wheel "$tmp"
/bin/chmod 0440 "$tmp"
/usr/sbin/visudo -cf "$tmp" || { /bin/rm -f "$tmp"; exit 65; }
if [ -f "$policy" ]; then /bin/mv -f "$policy" "$policy_backup"; fi
policy_replaced=1
/bin/mv -f "$tmp" "$policy"
/usr/sbin/visudo -c || exit 65
# Verify through the actual user; sudo skips includedir entries containing dots.
/usr/bin/sudo -u "$target_user" /usr/bin/sudo -n -k "$helper" check dns.flush >/dev/null || exit 77
trap - EXIT
/bin/rm -f "$helper_backup" "$policy_backup"
# Remove ignored legacy rule with dots only after active policy verification.
/bin/rm -f /private/etc/sudoers.d/com.neox.neoy.helper
# Root-only trusted installation is intentionally separate from the app's
# normal, unprivileged auto-upgrade path.
echo "installed $helper for $target_user"
