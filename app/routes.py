from flask import Blueprint, request, render_template, Response, jsonify, current_app
import psutil
from .config import creds, vpn
from .utils import isAdmin
import hashlib
from .models import Session, AdminCredentials  # Adjust based on actual structure

# Create a Blueprint
api = Blueprint('api', __name__)

@api.route("/")
def homePage():
    return render_template("index.html")

@api.route("/type")
def vpnType():
    return {"type": vpn.vpnName}

@api.route("/login")
def loginCheck():
    return {
        "success": isAdmin(request.args),
        "memory": max(
            (psutil.swap_memory().used + psutil.virtual_memory().used)
            / (psutil.swap_memory().total + psutil.virtual_memory().total)
            * 100,
            5,
        ),
        "cpu": max(psutil.cpu_percent(), 5),
    }

@api.route("/list")
def listUsers():
    if isAdmin(request.args):
        return vpn.listUsers()
    else:
        return []

@api.route("/create/<path:name>")
def createUser(name):
    if isAdmin(request.args):
        try:
            vpn.createUser(name)
            current_app.logger.info("Created VPN user %s", name)
            return {"success": True}
        except Exception as exc:
            current_app.logger.exception("Failed to create VPN user %s", name)
            return {"success": False, "error": str(exc)}, 500
    else:
        return {"success": False, "error": "Unauthorized"}, 403

@api.route("/remove/<path:name>")
def removeUser(name):
    if isAdmin(request.args):
        try:
            vpn.removeUser(name)
            current_app.logger.info("Removed VPN user %s", name)
            return {"success": True}
        except Exception as exc:
            current_app.logger.exception("Failed to remove VPN user %s", name)
            return {"success": False, "error": str(exc)}, 500
    else:
        return {"success": False, "error": "Unauthorized"}, 403

@api.route("/changeAdmin", methods=["POST"])
def changeAdmin():
    if not request.json:
        return jsonify({"success": False, "error": "No data provided"}), 400

    data = request.json
    newUsername = data.get("newUsername")
    newPassword = data.get("newPassword")

    if not newUsername or not newPassword:
        return jsonify({"success": False, "error": "Missing username or password"}), 400

    hashedNewPassword = hashlib.sha256(newPassword.encode('utf-8')).hexdigest()

    session = Session()
    admin_creds = session.query(AdminCredentials).first()
    if admin_creds:
        admin_creds.username = newUsername
        admin_creds.password = hashedNewPassword
    else:
        new_admin_creds = AdminCredentials(username=newUsername, password=hashedNewPassword)
        session.add(new_admin_creds)

    session.commit()
    session.close()

    return jsonify({"success": True, "message": "Admin credentials updated successfully."})

@api.route("/getConfig/<path:name>")
def getConfig(name):
    if isAdmin(request.args):
        return Response(
            vpn.getConfig(name),
            mimetype=f"text/x-{vpn.vpnExtension}",
            headers={
                "Content-Disposition": f"attachment;filename={name}.{vpn.vpnExtension}"
            },
        )
    else:
        return {"error": "Incorrect admin credentials!"}
