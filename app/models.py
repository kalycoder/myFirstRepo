# models.py
import hashlib

from sqlalchemy import create_engine, Column, Integer, String
from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.declarative import declarative_base

# Define your engine
engine = create_engine('sqlite:///admin.db')  # Adjust the database URL as needed

# Define your session factory
Session = sessionmaker(bind=engine)

# Define your declarative base class
Base = declarative_base()

def init_db():
    print("Initializing database...")
    Base.metadata.create_all(engine)  # Create tables if they don't exist
    session = Session()

    if session.query(AdminCredentials).count() == 0:
        hashed_password = hashlib.sha256('772d9c8450b0be00'.encode('utf-8')).hexdigest()
        admin = AdminCredentials(username='Administrator', password=hashed_password)
        session.add(admin)
    if session.query(User).count() == 0:
                # Hash the password using SHA-256
        hashed_password = hashlib.sha256('user'.encode('utf-8')).hexdigest()
        user = User(username='user', password=hashed_password)
        session.add(user)
    session.commit()
    session.close()





class AdminCredentials(Base):
    __tablename__ = 'admin_credentials'
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password = Column(String, nullable=False)

class User(Base):
    __tablename__ = 'users'
    id = Column(Integer, primary_key=True)
    username = Column(String, unique=True, nullable=False)
    password = Column(String, nullable=False)


Base.metadata.create_all(engine)

def shutdown():
    print("shutdown")

# Optionally, you can call init_db() here or from wherever you initialize your app
