#!/bin/sh
set -eu

stdlib="$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
apk add --no-cache --virtual .python-security-patch patch
for fix in /run/python-security/cpython-*.patch; do
    patch --batch --forward --fuzz=0 -p2 -d "${stdlib}" < "${fix}"
done
rm -f "${stdlib}"/__pycache__/poplib.*.pyc "${stdlib}"/http/__pycache__/client.*.pyc
apk del .python-security-patch

python3 /run/python-security/verify-python.py
