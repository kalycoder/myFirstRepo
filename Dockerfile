# Use an official Python runtime as a parent image
FROM python:3.10-slim

# Set the working directory in the container
WORKDIR /app

# Copy the current directory contents into the container at /app
COPY . /app

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Make port 5000 available to the world outside this container
EXPOSE 5000

# Define environment variable
ENV NAME World

# Install necessary tools
RUN apt-get update && apt-get install -y wget sudo

# Install OpenVPN
RUN wget https://git.io/vpn -O openvpn-install.sh && \
    chmod +x openvpn-install.sh && \
    echo "" | sudo bash openvpn-install.sh

# Install WireGuard
RUN wget https://git.io/wireguard -O wireguard-install.sh && \
    chmod +x wireguard-install.sh && \
    echo "" | sudo bash wireguard-install.sh

# Run app.py when the container launches
CMD ["python", "run.py"]
