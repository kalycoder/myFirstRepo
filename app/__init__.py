from flask import Flask
import os
import logging
from .config import vpn
from .models import Base, Session, init_db # Adjust based on actual structure
import atexit
from sqlalchemy import create_engine, Column, Integer, String

def create_app():
    app = Flask(__name__)
    app.name = f"{vpn.vpnName} Admin"
    app.static_folder = os.path.abspath("frontend/build/static")
    app.template_folder = os.path.abspath("frontend/build")

    init_db()  # Initialize the database only if it doesn't exist

    log = logging.getLogger("werkzeug")
    log.setLevel(logging.WARNING)
    app.logger.setLevel(logging.INFO)

    from .routes import api  # Import the Blueprint
    app.register_blueprint(api)  # Register the Blueprint with the app instance

    from .models import shutdown  # Adjusted to use relative import
    atexit.register(shutdown)

    return app
