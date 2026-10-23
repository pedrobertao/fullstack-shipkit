package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"my-project/internal/auth"
	"my-project/internal/config"
	"my-project/internal/db"
	"my-project/internal/logging"
	apihttp "my-project/internal/http"
	"my-project/internal/queue"
	"my-project/internal/service"
)

func main() {
	cfg := config.Load()
	logger := logging.New(cfg.Env, cfg.LogLevel)
	slog.SetDefault(logger)
	ctx := context.Background()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	must(logger, "postgres", err)
	defer pool.Close()

	opt, err := redis.ParseURL(cfg.RedisURL)
	must(logger, "redis url", err)
	rdb := redis.NewClient(opt)
	defer rdb.Close()

	pub, err := queue.NewPublisher(cfg.RabbitURL)
	must(logger, "rabbitmq", err)
	defer pub.Close()

	queries := db.New(pool)
	tokens := auth.NewTokenService(cfg.JWTSecret, rdb)
	userSvc := service.NewUserService(queries, pub)
	authSvc := service.NewAuthService(queries, tokens)

	app := apihttp.NewApp(logger, cfg, apihttp.Deps{
		Auth:   authSvc,
		Users:  userSvc,
		Tokens: tokens,
		Redis:  rdb,
	})

	go func() {
		if err := app.Listen(":" + cfg.Port); err != nil {
			logger.Error("server", "err", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	_ = app.Shutdown()
}

func must(l *slog.Logger, what string, err error) {
	if err != nil {
		l.Error("init "+what, "err", err)
		os.Exit(1)
	}
}
