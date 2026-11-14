"""Verify that native hashlib respects the OpenSSL FIPS property."""

import _hashlib
from ctypes import CDLL, c_int, c_void_p

# Enable the default FIPS property in this test process. MD5 is available
# through the default provider only when the caller opts out explicitly.
enable_fips = CDLL(_hashlib.__file__).EVP_default_properties_enable_fips
enable_fips.argtypes = (c_void_p, c_int)
enable_fips.restype = c_int
if enable_fips(None, 1) != 1 or _hashlib.get_fips_mode() != 1:
    raise SystemExit("Could not enable the OpenSSL FIPS property")

try:
    _hashlib.openssl_md5(b"abc", usedforsecurity=True)
except ValueError:
    pass
else:
    raise SystemExit("Security-sensitive MD5 bypassed the OpenSSL FIPS property")

if _hashlib.openssl_md5(b"abc", usedforsecurity=False).hexdigest() != "900150983cd24fb0d6963f7d28e17f72":
    raise SystemExit("Explicit non-security MD5 failed")
print("Native hashlib respects the OpenSSL FIPS property")
