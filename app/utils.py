from hashlib import sha256
from .config import creds
from.models import Session, AdminCredentials  # Adjust based on actual structure


def isAdmin(args):
    session = Session()
    admin_creds = session.query(AdminCredentials).first()
    session.close()
    if admin_creds:
        hashed_input_password = sha256(args.get("password").encode()).hexdigest() if args.get("password") else None
        expected_username = args.get("username") == admin_creds.username
        expected_password = hashed_input_password == admin_creds.password
        return expected_username and expected_password
    return False