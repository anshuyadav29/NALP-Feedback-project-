# Multi-stage Dockerfile for Issue Tracker
# Stage 1: Build stage (not used in CI/CD as we build with Gradle externally)
# Stage 2: Runtime stage

FROM eclipse-temurin:21-jre-alpine AS runtime

# Build arguments
ARG VERSION=0.0.1-SNAPSHOT
ARG JAR_FILE=backend/build/libs/*.jar

# Add metadata
LABEL org.opencontainers.image.title="Issue Tracker"
LABEL org.opencontainers.image.description="Modern issue tracking application with Kanban boards"
LABEL org.opencontainers.image.vendor="TFSolution"
LABEL org.opencontainers.image.source="https://github.com/freefair/issue-tracker"
LABEL org.opencontainers.image.version="${VERSION}"

# Create app user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Set working directory
WORKDIR /app

# Copy the JAR file
COPY ${JAR_FILE} app.jar

# Change ownership to app user
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# JVM options for container
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC"

# Run the application
ENTRYPOINT ["sh", "-c", "java ${JAVA_OPTS} -jar app.jar"]
