FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
CMD ["/usr/sbin/httpd", "-D", "FOREGROUND"]
