from pathlib import Path
from typing import Optional
import subprocess
import os

vpnName = "OpenVPN"
vpnExtension = "ovpn"


class OpenVPNPaths:
    def __init__(
        self,
        easy_rsa: Path,
        client_template: Optional[Path],
        tls_crypt: Optional[Path],
        tls_auth: Optional[Path],
        crl_destination: Path,
    ) -> None:
        self.easy_rsa = easy_rsa
        self.pki = easy_rsa / "pki"
        self.client_template = client_template
        self.tls_crypt = tls_crypt
        self.tls_auth = tls_auth
        self.crl_destination = crl_destination


def _detect_paths() -> OpenVPNPaths:
    candidates: list[dict[str, str | None]] = [
        {
            "easy_rsa": "/etc/openvpn/easy-rsa",
            "client_template": "/etc/openvpn/client-template.txt",
            "tls_crypt": "/etc/openvpn/tls-crypt.key",
            "tls_auth": "/etc/openvpn/tls-auth.key",
            "crl_destination": "/etc/openvpn/crl.pem",
        },
        {
            "easy_rsa": "/etc/openvpn/server/easy-rsa",
            "client_template": "/etc/openvpn/server/client-common.txt",
            "tls_crypt": "/etc/openvpn/server/tc.key",
            "tls_auth": "/etc/openvpn/server/tc.key",
            "crl_destination": "/etc/openvpn/server/crl.pem",
        },
    ]

    for candidate in candidates:
        easy_rsa = Path(candidate["easy_rsa"])
        if easy_rsa.is_dir():
            client_template = (
                Path(candidate["client_template"])
                if candidate.get("client_template")
                else None
            )
            tls_crypt = (
                Path(candidate["tls_crypt"]) if candidate.get("tls_crypt") else None
            )
            tls_auth = (
                Path(candidate["tls_auth"]) if candidate.get("tls_auth") else None
            )
            crl_destination = Path(candidate["crl_destination"])
            return OpenVPNPaths(
                easy_rsa=easy_rsa,
                client_template=client_template if client_template and client_template.exists() else None,
                tls_crypt=tls_crypt if tls_crypt and tls_crypt.exists() else None,
                tls_auth=tls_auth if tls_auth and tls_auth.exists() else None,
                crl_destination=crl_destination,
            )

    raise RuntimeError(
        "Supported OpenVPN installation not found. Ensure easy-rsa is installed."
    )


_PATHS: Optional[OpenVPNPaths] = None


def _get_paths() -> OpenVPNPaths:
    global _PATHS
    if _PATHS is None:
        _PATHS = _detect_paths()
    return _PATHS


def _run_command(command: list[str], cwd: Path | None = None) -> None:
    env = os.environ.copy()
    env.setdefault(
        "PATH",
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )
    subprocess.run(command, check=True, cwd=cwd, env=env)


def _read_file(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def createUser(user: str) -> None:
    if user in listUsers():
        return

    paths = _get_paths()

    _run_command(
        ["./easyrsa", "--batch", "--days=3650", "build-client-full", user, "nopass"],
        cwd=paths.easy_rsa,
    )


def getConfig(user: str) -> str:
    paths = _get_paths()

    if paths.client_template and paths.client_template.exists():
        config_parts = [paths.client_template.read_text(encoding="utf-8")]
    else:
        raise FileNotFoundError(
            "OpenVPN client template not found. Expected client-template.txt or client-common.txt."
        )

    ca_path = paths.pki / "ca.crt"
    cert_path = paths.pki / "issued" / f"{user}.crt"
    key_path = paths.pki / "private" / f"{user}.key"
    tls_key_path = paths.tls_crypt or paths.tls_auth

    if not cert_path.exists() or not key_path.exists():
        raise FileNotFoundError(
            f"Certificate or key for user '{user}' not found. Ensure the profile exists."
        )

    config_parts.append("<ca>\n" + _read_file(ca_path).strip() + "\n</ca>\n")
    config_parts.append("<cert>\n" + _read_file(cert_path).strip() + "\n</cert>\n")
    config_parts.append("<key>\n" + _read_file(key_path).strip() + "\n</key>\n")

    if tls_key_path and tls_key_path.exists():
        tag = "tls-crypt" if tls_key_path.name.endswith("crypt.key") else "tls-auth"
        config_parts.append(f"<{tag}>\n" + _read_file(tls_key_path).strip() + f"\n</{tag}>\n")

    config = "".join(config_parts)

    config = config.replace(
        "cipher AES-256-CBC",
        "cipher AES-128-CBC\ntun-mtu 60000\ntun-mtu-extra 32\nmssfix 1450\nfast-io",
    )

    return config


def listUsers() -> list[str]:
    try:
        paths = _get_paths()
    except RuntimeError:
        return []

    index_file = paths.pki / "index.txt"
    if not index_file.exists():
        return []

    users: list[str] = []
    for line in index_file.read_text(encoding="utf-8").splitlines():
        if not line.startswith("V"):
            continue
        parts = line.split("/")
        for part in parts:
            if part.startswith("CN="):
                users.append(part.replace("CN=", ""))
                break
    return users


def removeUser(user: str) -> None:
    if user not in listUsers():
        return
    paths = _get_paths()

    _run_command(["./easyrsa", "--batch", "revoke", user], cwd=paths.easy_rsa)
    _run_command(
        ["./easyrsa", "--batch", "--days=3650", "gen-crl"], cwd=paths.easy_rsa
    )

    crl_source = paths.pki / "crl.pem"
    _run_command(["cp", str(crl_source), str(paths.crl_destination)])
    _run_command(["chown", "nobody:nogroup", str(paths.crl_destination)])


def parse_log() -> None:
    log_path = Path("/var/log/openvpn/status.log")
    if not log_path.exists():
        print(f"Error: The file {log_path} does not exist.")
        return

    lines = log_path.read_text(encoding="utf-8").splitlines()
    try:
        client_start = lines.index("OpenVPN CLIENT LIST") + 2
        client_end = lines.index("ROUTING TABLE") - 1
    except ValueError:
        print("Error: The necessary log markers are missing.")
        return

    print("User Sessions:")
    for client in lines[client_start:client_end]:
        details = client.split(",")
        if len(details) >= 5:
            print(
                f"User: {details[0]}, IP: {details[1]}, Received: {details[2]}, "
                f"Sent: {details[3]}, Connected Since: {details[4]}"
            )
