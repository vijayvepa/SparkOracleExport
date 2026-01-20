FROM bitnami/spark:3.5.0

# Image for running PySpark jobs against MySQL using JDBC.
# This Dockerfile assumes:
#   - A real MySQL JDBC driver jar (e.g. mysql-connector-j.jar) will be placed in
#     docker/spark/drivers/ before building the image.

USER root

# Create directory for custom JDBC drivers
RUN mkdir -p /opt/bitnami/spark/jdbc-drivers

# Copy MySQL JDBC driver into Spark's classpath.
# IMPORTANT: Replace the placeholder mysql-connector-j.jar file with the real driver
# before building this image.
COPY drivers/mysql-connector-j.jar /opt/bitnami/spark/jdbc-drivers/mysql-connector-j.jar

# Make sure the driver is also visible on the main Spark jars path.
RUN cp /opt/bitnami/spark/jdbc-drivers/mysql-connector-j.jar /opt/bitnami/spark/jars/mysql-connector-j.jar

# Working directory where the SparkApplication will point to etl_job.py
WORKDIR /opt/spark-app

# Copy application code and config at build time (paths may be overridden
# or extended by the SparkApplication volumes/configs if desired).
COPY src/main/python/ /opt/spark-app/
COPY config/ /opt/spark-app/config/

USER 1001

