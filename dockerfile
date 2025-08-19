# Use the official Red Hat Universal Base Image 9 (Minimal) as the foundation.
# It's a secure and lightweight starting point.
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Install the Apache HTTP Server (httpd) package using the dnf package manager.
# The '-y' flag automatically answers 'yes' to any prompts.
# 'dnf clean all' removes cached package files to keep the final image small.
RUN dnf install -y httpd && dnf clean all

# Copy our simple website file from our local machine into the container.
# The destination '/var/www/html/' is the default web root directory for httpd.
COPY index.html /var/www/html/

# Inform the container runtime that the container will listen on port 80 at runtime.
EXPOSE 80

# This is the command that will run when the container starts.
# It starts the httpd server in the foreground, which is standard practice for containers.
CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]
