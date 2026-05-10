"""Domain-specific error types and JSON-RPC error codes."""

from __future__ import annotations

from .rpc import RpcError

# Domain error codes (must lie in the JSON-RPC server-error range:
# -32000 to -32099 reserved for the implementation).
DEVICE_NOT_FOUND = -32001
DEVICE_NOT_CONNECTED = -32002
UNSUPPORTED_IOS = -32003
TUNNEL_FAILED = -32004
DEVICE_LOST = -32005
PYMD3_ERROR = -32006


def device_not_found(udid: str) -> RpcError:
    return RpcError(code=DEVICE_NOT_FOUND, message=f"Device not found: {udid}")


def device_not_connected(udid: str) -> RpcError:
    return RpcError(
        code=DEVICE_NOT_CONNECTED,
        message=f"Device not connected: {udid}",
        data={"hint": "call device.connect first"},
    )


def unsupported_ios(version: str, minimum: str = "16.0") -> RpcError:
    return RpcError(
        code=UNSUPPORTED_IOS,
        message=f"iOS {version} is below the minimum supported version {minimum}",
        data={"version": version, "minimum": minimum},
    )


def tunnel_failed(udid: str, detail: str) -> RpcError:
    return RpcError(
        code=TUNNEL_FAILED,
        message=f"Tunnel setup failed for {udid}: {detail}",
        data={"udid": udid, "hint": "iOS 17+ tunnel needs root; consider USB instead"},
    )


def device_lost(udid: str) -> RpcError:
    return RpcError(
        code=DEVICE_LOST,
        message=f"Device {udid} appears to be gone (USB unplugged or tunnel dead)",
    )
