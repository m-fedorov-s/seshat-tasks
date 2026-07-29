package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Secret   string `yaml:"secret"`
	Port     uint   `yaml:"port"`
	DataFile string `yaml:"data_file"`
	// RateLimit is the requests-per-second ceiling. 0 means use defaultRateLimit.
	RateLimit int `yaml:"rate_limit"`
}

func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	flag.Parse()

	raw, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		log.Fatal(err)
	}
	if cfg.DataFile == "" {
		cfg.DataFile = "seshat-data.json"
	}
	if cfg.RateLimit == 0 {
		cfg.RateLimit = defaultRateLimit
	}
	if cfg.RateLimit < 0 {
		log.Fatalf("config rate_limit must be positive, got %d", cfg.RateLimit)
	}

	store, err := NewStore(cfg.DataFile)
	if err != nil {
		log.Fatalf("load store: %v", err)
	}
	srv := NewServer(store, cfg.Secret, cfg.RateLimit)

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("seshat server listening on %s, data=%s", addr, cfg.DataFile)
	if err := http.ListenAndServe(addr, srv.Handler()); err != nil {
		log.Fatal(err)
	}
}
