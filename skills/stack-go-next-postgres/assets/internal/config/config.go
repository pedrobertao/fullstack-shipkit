package config

import (
	"log"
	"os"
	"strings"
)

type Config struct {
	Port        string
	Env         string // "dev" | "prod"
	LogLevel    string // "debug" | "info" | "warn" | "error"
	DatabaseURL string
	RedisURL    string
	RabbitURL   string
	JWTSecret   string
	FrontendURL string // CORS and cookies
}

// Load reads configuration from the environment. The three secret-shaped
// values (JWTSecret, DatabaseURL, RabbitURL) go through getSecret instead
// of a plain os.Getenv — see getSecret for what that buys you.
func Load() Config {
	cfg := Config{
		Port:        getEnv("API_PORT", "8080"),
		Env:         getEnv("ENV", "dev"),
		LogLevel:    getEnv("LOG_LEVEL", "info"),
		DatabaseURL: getSecret("DATABASE_URL"),
		RedisURL:    getEnv("REDIS_URL", "redis://localhost:6379/0"),
		RabbitURL:   getSecret("RABBITMQ_URL"),
		JWTSecret:   getSecret("JWT_SECRET"),
		FrontendURL: getEnv("FRONTEND_URL", "http://localhost:3000"),
	}

	if cfg.Env == "prod" && cfg.JWTSecret == "" {
		log.Fatal("config: JWT_SECRET (or JWT_SECRET_FILE) is empty in production")
	}
	return cfg
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// getSecret reads KEY, but first checks whether KEY_FILE is set. If it is,
// the value is read from that file on disk instead of from the environment
// directly. This one function is what lets the exact same binary work in
// three setups without any code change:
//
//   - local dev, value inline in .env:        JWT_SECRET=abc123...
//   - local dev, value in a gitignored file:   JWT_SECRET_FILE=./secrets/jwt_secret.txt
//   - containerized, Docker Compose secret:    JWT_SECRET_FILE=/run/secrets/jwt_secret
//
// In the last case Compose mounts the secret at that path itself — nothing
// in this code needs to know Docker is involved.
func getSecret(key string) string {
	if path := os.Getenv(key + "_FILE"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			log.Fatalf("config: reading secret file for %s at %s: %v", key, path, err)
		}
		return strings.TrimSpace(string(b))
	}
	return os.Getenv(key)
}
