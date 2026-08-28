# ---------- Stage 1: Build the jar ----------
FROM eclipse-temurin:25-jdk AS builder
WORKDIR /app

# Copy Gradle wrapper and build files first — this layer caches as long as they don't change.
COPY gradle/ gradle
COPY gradlew build.gradle.kts settings.gradle.kts ./
RUN ./gradlew dependencies --no-daemon

# Now copy source and build. Changes to source only invalidate this layer.
COPY src ./src
RUN ./gradlew bootJar --no-daemon

# ---------- Stage 2: Extract layered jar ----------
FROM eclipse-temurin:25-jdk AS extractor
WORKDIR /app
COPY --from=builder /app/build/libs/*.jar app.jar
RUN java -Djarmode=layertools -jar app.jar extract

# ---------- Stage 3: Runtime image ----------
FROM eclipse-temurin:25-jre
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && rm -rf /var/lib/apt/lists/*

# Copy each layer in increasing order of change frequency.
# Docker can cache early layers when only application code changes.
COPY --from=extractor /app/dependencies/ ./
COPY --from=extractor /app/spring-boot-loader/ ./
COPY --from=extractor /app/snapshot-dependencies/ ./
COPY --from=extractor /app/application/ ./

EXPOSE 8082
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
