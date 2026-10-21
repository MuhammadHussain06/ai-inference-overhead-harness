# Build stage: Maven wrapper build with tests skipped.
# dos2unix guards against a CRLF mvnw from a Windows checkout.
FROM eclipse-temurin:21.0.12_8-jdk-alpine@sha256:cd87715a8d45cfaa42419207c64680234f62785c49055cccd20437b5c9018380 AS build
WORKDIR /app
COPY . .
RUN apk add --no-cache dos2unix && dos2unix mvnw && chmod +x mvnw && ./mvnw clean package -DskipTests

# Run stage: JRE only. JVM options come from JAVA_TOOL_OPTIONS in docker-compose.yml.
FROM eclipse-temurin:21.0.12_8-jre-alpine@sha256:1a29e1fe337eb28b5bec30f0ee8ed29f0ff80ab6f75dcf9313efe82911065a52
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
