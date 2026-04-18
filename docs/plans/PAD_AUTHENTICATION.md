# Pad Authentication System

This document describes how Pad devices are authenticated in the server system and how Django API views access authenticated pad information.

## Table of Contents

1. [Overview](#overview)
2. [Authentication Flow](#authentication-flow)
3. [Device Serial Number (SN) Generation](#device-serial-number-sn-generation)
4. [Signature Encryption](#signature-encryption)
5. [API Integration](#api-integration)
6. [Accessing Pad Information in Views](#accessing-pad-information-in-views)
7. [Configuration Options](#configuration-options)
8. [Security Considerations](#security-considerations)

## Overview

The Pad authentication system uses a signature-based mechanism where Pad devices send encrypted authentication information in HTTP headers. The server validates this signature and attaches pad information to the request object for use in API views.

**Key Components:**
- **Signature Header**: Encrypted device information sent by the client
- **Timestamp Header**: Request timestamp for replay attack prevention
- **Device SN Validation**: Verification of device serial numbers
- **AES Encryption**: CBC mode encryption for signature protection

## Authentication Flow

```
┌─────────────┐                                    ┌─────────────┐
│   Pad       │                                    │   Server    │
│   Device    │                                    │   (Django)  │
└──────┬──────┘                                    └──────┬──────┘
       │                                                  │
       │  1. Generate signature payload:                 │
       │     app_build_num|mac|sn|system_version|time    │
       │                                                  │
       │  2. Encrypt with AES-CBC                        │
       │     (key: qWTF5bFmf6r5q9TZ)                    │
       │     (iv:  s3m2gbx76eq3d25t)                    │
       │                                                  │
       │  3. Base64 encode encrypted data                │
       │                                                  │
       │  4. Send HTTP request:                          │
       │     Header: Signature = <encrypted_data>        │
       │     Header: Timestamp = <unix_timestamp>        │
       ├─────────────────────────────────────────────────>│
       │                                                  │
       │                              5. Validate request │
       │                                 (check_sign())   │
       │                                                  │
       │                              6. Decrypt signature│
       │                                 (decrypt_pad_sign())│
       │                                                  │
       │                              7. Verify timestamp │
       │                                                  │
       │                              8. Check device SN  │
       │                                 (check_device_sn())│
       │                                                  │
       │                              9. Create Pad object│
       │                                                  │
       │                             10. Attach to request│
       │                                 (request.pad)    │
       │                                                  │
       │                             11. Process API view │
       │<─────────────────────────────────────────────────┤
       │                                                  │
```

## Device Serial Number (SN) Generation

Device serial numbers follow a specific 12-character format defined in [pronext/core/sn.py](../pronext/core/sn.py):

### Format Structure

```
[AA][BBBBBB][CCCC]
 ││    │       │
 ││    │       └─ 4 chars: Sequential index (hexadecimal)
 ││    └───────── 6 chars: Verification code (uppercase)
 │└────────────── 2 chars: Batch identifier (uppercase letters)
```

**Example:** `AB1A2B3C0001`
- `AB` - Batch identifier
- `1A2B3C` - Verification code (MD5-based)
- `0001` - Device index in hexadecimal

### SN Generation Algorithm

```python
def sign_device_sn(prefix: str, index: str) -> str:
    """
    Generates a 6-character verification code for a device SN.

    Args:
        prefix: 2-character batch identifier (e.g., 'AB')
        index: 4-character device index (e.g., '0001')

    Returns:
        6-character uppercase verification code
    """
    prefix = prefix.upper()
    origin = f"{prefix}--{index}--{SN_SECRET}"
    origin_md5 = hashlib.md5(origin.encode()).hexdigest()
    sign = origin_md5[:6].upper()
    return sign
```

**Secret Key:** `ZobKlPrxoGW0YyQS5KOTZ3rb6YUMP0c6`

### SN Validation

```python
def check_device_sn(sn: str) -> bool:
    """
    Validates a device serial number.

    Returns:
        True if SN is valid, False otherwise
    """
    if len(sn) != 12:
        return False

    prefix = sn[:2]      # Extract batch identifier
    index = sn[8:]       # Extract device index
    expected_sign = sign_device_sn(prefix, index)
    actual_sign = sn[2:8]  # Extract verification code

    return expected_sign == actual_sign
```

## Signature Encryption

The signature uses **AES-128-CBC** encryption defined in [pronext/core/sign.py](../pronext/core/sign.py#L53-L68).

### Encryption Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Algorithm | AES-128-CBC | Advanced Encryption Standard, CBC mode |
| Key | `qWTF5bFmf6r5q9TZ` | 16-byte encryption key |
| IV | `s3m2gbx76eq3d25t` | 16-byte initialization vector |
| Encoding | Base64 | Final encoding for transmission |

### Signature Payload Format

The plaintext signature contains pipe-delimited fields:

```
app_build_num|mac|sn|system_version|timestamp
```

**Example:**
```
123|AA:BB:CC:DD:EE:FF|AB1A2B3C0001|11|1698765432
```

### Decryption Process

```python
def decrypt_pad_sign(data: str) -> str:
    """
    Decrypts the Pad signature from the Signature header.

    Args:
        data: Base64-encoded encrypted signature

    Returns:
        Decrypted plaintext signature string

    Raises:
        PronextException: If decryption fails
    """
    key = b'qWTF5bFmf6r5q9TZ'
    iv = b's3m2gbx76eq3d25t'

    encrypted_data = b64decode(data)
    cipher = AES.new(key, AES.MODE_CBC, iv)
    plaintext = unpad(cipher.decrypt(encrypted_data), AES.block_size)

    return plaintext.decode()
```

## API Integration

Authentication is automatically enforced for all API endpoints through the `GenericViewSet` class in [pronext/core/api.py](../pronext/core/api.py#L57-L78).

### Automatic Authentication

```python
class GenericViewSet(viewsets.GenericViewSet):
    renderer_classes = [JSONRenderer]
    pagination_class = PagePagination

    def initial(self, request, *args, **kwargs):
        # Signature check happens before any view logic
        check_sign(request)
        return super().initial(request, *args, **kwargs)
```

### Check Sign Function

The `check_sign()` function in [pronext/core/sign.py](../pronext/core/sign.py#L30-L51) performs the authentication:

```python
def check_sign(request):
    """
    Validates the request signature and attaches Pad information.

    Only processes requests to /pad-api/* endpoints.

    Side effects:
        - Adds 'pad' attribute to request object
        - Raises PronextException if validation fails
    """
    timestamp = request.headers.get('Timestamp')
    sign = request.headers.get('Signature', '')

    # Only check signature for Pad API endpoints
    if request.path.startswith('/pad-api/'):
        if sign == '':
            raise PronextException('Invalid signature')

        # Decrypt the signature
        origin = decrypt_pad_sign(sign)

        # Parse signature components
        app_build_num, mac, sn, system_version, time = origin.split('|')

        # Verify timestamp matches
        if time != timestamp:
            raise PronextException('Invalid signature')

        # Optionally verify device SN
        if global_config().pad_api_check_sign and not check_device_sn(sn):
            raise PronextException('Invalid signature')

        # Create Pad object and attach to request
        pad = Pad(int(app_build_num), mac, sn, system_version)
        setattr(request, 'pad', pad)
```

### Pad Object Structure

```python
class Pad:
    """
    Represents an authenticated Pad device.
    """
    app_build_num: int       # App version build number
    mac: str                 # Device MAC address
    sn: str                  # Device serial number
    system_version: str      # Android system version
```

**Special SN Handling:**

For devices in the `use_sn_mac_sns` configuration list, the SN is modified to include the MAC address:

```python
if sn in global_config().use_sn_mac_sns:
    self.sn = f'{sn}__{mac}'
else:
    self.sn = sn
```

## Accessing Pad Information in Views

After successful authentication, API views can access the Pad object through the request.

### Example: Basic Access

```python
from pronext.core.api import GenericViewSet, register_pad_route
from rest_framework.decorators import action
from rest_framework.response import Response

@register_pad_route('device')
class DeviceViewSet(GenericViewSet):

    @action(detail=False, methods=['get'])
    def info(self, request):
        # Access authenticated pad information
        pad = request.pad

        return Response({
            'sn': pad.sn,
            'mac': pad.mac,
            'app_build_num': pad.app_build_num,
            'system_version': pad.system_version
        })
```

### Example: Using Pad SN for Database Queries

```python
from pronext.core.api import GenericViewSet, register_pad_route
from rest_framework.decorators import action
from rest_framework.response import Response
from ..models import Device

@register_pad_route('settings')
class SettingsViewSet(GenericViewSet):

    @action(detail=False, methods=['get'])
    def get_device_settings(self, request):
        # Use pad SN to query device-specific settings
        device = Device.objects.get(sn=request.pad.sn)

        return Response({
            'device_name': device.name,
            'settings': device.settings_data
        })
```

### Example: Checking App Version

```python
from pronext.core.api import GenericViewSet, register_pad_route
from rest_framework.decorators import action
from rest_framework.response import Response
from pronext.core.exceptions import PronextException

@register_pad_route('feature')
class FeatureViewSet(GenericViewSet):

    MINIMUM_VERSION = 100

    @action(detail=False, methods=['post'])
    def new_feature(self, request):
        # Enforce minimum app version
        if request.pad.app_build_num < self.MINIMUM_VERSION:
            raise PronextException(
                f'This feature requires app version {self.MINIMUM_VERSION} or higher'
            )

        # Process the new feature request
        return Response({'status': 'success'})
```

## Accessing User Information

The `GenericViewSet` also handles user authentication alongside pad authentication:

```python
def perform_authentication(self, request):
    """
    Performs user authentication if permissions are required.
    Sets request.user to None if no permissions are specified.
    """
    if not self.get_permissions():
        request.user = None
    return super().perform_authentication(request)
```

### Example: Using Both User and Pad

```python
from pronext.core.api import GenericViewSet, register_pad_route
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response

@register_pad_route('user-device')
class UserDeviceViewSet(GenericViewSet):
    permission_classes = [IsAuthenticated]

    @action(detail=False, methods=['post'])
    def link_device(self, request):
        # Access both user and pad information
        user = request.user  # Django user object
        pad = request.pad    # Pad object

        # Link the device to the user
        device = Device.objects.get(sn=pad.sn)
        device.user = user
        device.save()

        return Response({
            'status': 'success',
            'user_id': user.id,
            'device_sn': pad.sn
        })
```

## Configuration Options

The authentication system uses global configuration from `pronext.config.models.global_config()`:

### pad_api_check_sign

Controls whether device SN validation is enforced:

```python
if global_config().pad_api_check_sign and not check_device_sn(sn):
    raise PronextException('Invalid signature')
```

- **Type:** Boolean
- **Default:** Should be `True` in production
- **Purpose:** Enables/disables strict SN validation

### use_sn_mac_sns

List of SNs that should have MAC address appended:

```python
if sn in global_config().use_sn_mac_sns:
    self.sn = f'{sn}__{mac}'
```

- **Type:** List of strings
- **Purpose:** Handles special cases where SN alone is not unique

## Security Considerations

### 1. Encryption Key Management

**Current Status:** Hardcoded encryption keys in [pronext/core/sign.py](../pronext/core/sign.py#L54)

```python
def decrypt_pad_sign(data: str) -> str:
    return _decrypt_sign(data, 'qWTF5bFmf6r5q9TZ', 's3m2gbx76eq3d25t')
```

**Recommendation:** Move keys to environment variables or secure key management system.

### 2. Replay Attack Prevention

The system uses timestamp validation to prevent replay attacks:

```python
if time != timestamp:
    raise PronextException('Invalid signature')
```

**Limitation:** No maximum time window enforcement. Consider adding:

```python
current_time = int(time.time())
request_time = int(time)
if abs(current_time - request_time) > 300:  # 5 minute window
    raise PronextException('Request timestamp expired')
```

### 3. Device SN Secret

The SN validation secret is hardcoded in [pronext/core/sn.py](../pronext/core/sn.py#L3):

```python
SN_SECRET = "ZobKlPrxoGW0YyQS5KOTZ3rb6YUMP0c6"
```

**Recommendation:** Move to environment configuration.

### 4. Signature Validation Scope

Authentication only applies to `/pad-api/*` endpoints:

```python
if request.path.startswith('/pad-api/'):
    # Perform signature validation
```

Other endpoints (`/app-api/*`) may have different authentication mechanisms.

### 5. Error Information Disclosure

The system logs detailed error information but returns generic messages to clients:

```python
except Exception as e:
    e = traceback.format_exc(-10)
    logger.error(f'decrypt sign error: {e}')
    raise PronextException('Invalid signature')
```

This prevents information leakage while maintaining debugging capability.

## Summary

The Pad authentication system provides:

1. **Strong Authentication:** AES-CBC encryption of device credentials
2. **Device Validation:** Serial number verification using MD5-based checksums
3. **Easy Integration:** Automatic attachment of pad information to request objects
4. **Flexible Configuration:** Optional SN validation and special device handling
5. **Security:** Timestamp validation and error handling

**Key Access Patterns:**
- `request.pad.sn` - Device serial number
- `request.pad.mac` - Device MAC address
- `request.pad.app_build_num` - App version
- `request.pad.system_version` - Android version
- `request.user` - Django user object (when authenticated)
